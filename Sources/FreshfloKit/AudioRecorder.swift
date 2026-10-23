import AVFoundation
import CoreAudio

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? { "No microphone input available" }
}

/// Captures an input device and resamples it to 16 kHz mono Float32.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    /// Receives each converted 16 kHz chunk on the audio thread (used by the live preview).
    var onChunk: (([Float]) -> Void)?
    /// Low / mid / high band loudness (0…1) for each chunk, delivered on the main thread.
    var onBands: ((SIMD3<Float>) -> Void)?
    // One-pole filter state for the band split (touched only on the audio thread).
    private var lp300: Float = 0
    private var lp2k: Float = 0
    /// CoreAudio UID of the device to record from; empty uses the system default.
    var deviceUID = ""
    /// Recording stopped because the input device changed or disappeared; the owner restarts on the next best mic.
    var onDeviceLost: (() -> Void)?
    /// The same mic needs restarting after macOS reconfigured audio (nothing for the user to see).
    var onEngineReset: (() -> Void)?
    /// When false, audio is only streamed through `onChunk` (long meetings would otherwise fill memory).
    var retainSamples = true
    private(set) var isRecording = false

    private var samples: [Float] = []
    private let lock = NSLock()
    private var peak: Float = 0
    /// Listens for a human voice in what's being recorded (pitch + room noise), live.
    private var voice = VoiceSense.Tracker()

    /// Seconds of voice so far, and seconds since the voice last spoke.
    var voiceSoFar: (voiced: Double, since: Double) {
        lock.lock(); defer { lock.unlock() }
        return (voice.voicedSeconds, voice.sinceVoice)
    }

    /// Loudest sample so far; ~0 means the mic is delivering silence (muted or dead device).
    var peakSoFar: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
    /// Recording runs through AVCaptureSession, which opens any mic on its own. (AVAudioEngine ties the mic to the
    /// current speakers, and with AirPods or Bluetooth headphones as speakers the Mac's own mic delivered nothing at all.)
    /// The session is reused between recordings of the same mic, so the next dictation starts instantly.
    private var session: AVCaptureSession?
    private var sessionUID: String?
    private let sink = Sink()
    private let queue = DispatchQueue(label: "app.freshflo.mic", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []

    /// Receives 16 kHz mono Float32 buffers from the capture session.
    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        var onChunk: (([Float]) -> Void)?
        func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer, length >= 4 else { return }
            let count = length / MemoryLayout<Float>.size
            let chunk = pointer.withMemoryRebound(to: Float.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
            onChunk?(chunk)
        }
    }

    private func device() -> AVCaptureDevice? {
        if !deviceUID.isEmpty, let d = AVCaptureDevice(uniqueID: deviceUID) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    private func makeSession() throws -> AVCaptureSession {
        if let session, sessionUID == deviceUID { return session }
        teardown()
        guard let device = device() else { throw RecorderError.noInput }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { throw RecorderError.noInput }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(sink, queue: queue)
        guard session.canAddOutput(output) else { throw RecorderError.noInput }
        session.addOutput(output)
        sink.onChunk = { [weak self] in self?.process($0) }
        let center = NotificationCenter.default
        // The mic was unplugged or the headset turned off: the owner moves to the next best mic.
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.teardown()
            if self.isRecording { self.isRecording = false; self.onDeviceLost?() }
        })
        // macOS interrupted the session (audio reconfigured): same mic, restart quietly.
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.teardown()
            guard self.isRecording else { return }
            self.isRecording = false
            if AVCaptureDevice(uniqueID: self.deviceUID) != nil || self.deviceUID.isEmpty { self.onEngineReset?() } else { self.onDeviceLost?() }
        })
        self.session = session
        sessionUID = deviceUID
        return session
    }

    private func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let session, session.isRunning { session.stopRunning() }
        session = nil
        sessionUID = nil
    }

    /// Number of samples captured so far (for chunked transcription while still recording).
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lower = max(0, min(range.lowerBound, samples.count)), upper = max(lower, min(range.upperBound, samples.count))
        return Array(samples[lower..<upper])
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); peak = 0; voice = VoiceSense.Tracker(); lock.unlock()
        var session = try makeSession()
        if !session.isRunning { session.startRunning() }
        if !session.isRunning {
            // A reused session can go stale after devices change; try once more with a fresh one.
            teardown()
            session = try makeSession()
            session.startRunning()
            guard session.isRunning else { teardown(); throw RecorderError.noInput }
        }
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        session?.stopRunning()
        queue.sync {}   // let the last buffers land
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ chunk: [Float]) {
        guard isRecording, !chunk.isEmpty else { return }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        let db = 20 * log10(max(rms, 1e-6))
        let loudness = min(1, max(0, (db + 55) / 45))

        lock.lock()
        if retainSamples { samples.append(contentsOf: chunk) }
        peak = max(peak, chunk.map(abs).max() ?? 0)
        voice.feed(chunk)
        let voiceLevel = voice.voiceLevel
        lock.unlock()
        // The indicator follows your voice: a typed key or a fan barely moves it; talking makes it dance.
        let level = loudness * (0.35 + 0.65 * min(1, voiceLevel * 1.4))
        onChunk?(chunk)
        if onBands != nil {
            let bands = splitBands(chunk)
            DispatchQueue.main.async { [weak self] in self?.onBands?(bands) }
        }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Cheap 3-band split at 16 kHz: <300 Hz (voice body), 300 Hz–2 kHz (vowels), >2 kHz (consonants, sibilance).
    private func splitBands(_ chunk: [Float]) -> SIMD3<Float> {
        let a1: Float = 1 - exp(-2 * .pi * 300 / 16_000)
        let a2: Float = 1 - exp(-2 * .pi * 2_000 / 16_000)
        var e = SIMD3<Float>(repeating: 0)
        for x in chunk {
            lp300 += a1 * (x - lp300)
            lp2k += a2 * (x - lp2k)
            let low = lp300, mid = lp2k - lp300, high = x - lp2k
            e += SIMD3(low * low, mid * mid, high * high)
        }
        let n = Float(max(1, chunk.count))
        func norm(_ v: Float, _ gain: Float) -> Float {
            let db = 20 * log10(max(sqrt(v / n) * gain, 1e-6))
            return min(1, max(0, (db + 55) / 45))
        }
        // High frequencies carry far less energy in speech; boost them so all three bands move.
        return SIMD3(norm(e.x, 1), norm(e.y, 1.6), norm(e.z, 4))
    }

    /// 16 kHz mono Float32, for converting audio files.
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    // MARK: - Processing

    /// Drops leading/trailing silence (keeping a little padding) and reports how much speech remains.
    /// Silence is what makes Whisper hallucinate ("Thank you."), so it never gets uploaded.
    static func trimSilence(_ s: [Float]) -> (samples: [Float], voicedSeconds: Double) {
        let frame = 320 // 20 ms
        let frames = s.count / frame
        guard frames >= 5 else { return ([], 0) }
        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) { sum += s[i] * s[i] }
            rms[f] = sqrt(sum / Float(frame))
        }
        let noiseFloor = rms.sorted()[frames / 10]
        // Low absolute floor so whispered speech (RMS ≈ 0.003) still counts as voice in a quiet room.
        // Capped, because when someone talks the whole time the "quietest tenth" is their own voice: without the
        // cap, continuous speech was mistaken for background and cut away.
        let threshold = max(0.0025, min(noiseFloor * 3, 0.01))
        let voiced = rms.indices.filter { rms[$0] > threshold }
        guard let first = voiced.first, let last = voiced.last else { return ([], 0) }
        let pad = 15 // 300 ms
        let start = max(0, first - pad) * frame
        let end = min(frames, last + pad + 1) * frame
        return (Array(s[start..<end]), Double(voiced.count) * 0.02)
    }

    /// Whisper mode: quiet or distant speech is boosted to a normal level before transcription (gain up to 12×,
    /// soft-limited so peaks never clip). Normal-level speech is returned unchanged.
    static func normalizeQuiet(_ s: [Float]) -> [Float] {
        let frame = 320
        guard s.count >= frame * 5 else { return s }
        var levels: [Float] = []
        for f in 0..<(s.count / frame) {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) { sum += s[i] * s[i] }
            levels.append(sqrt(sum / Float(frame)))
        }
        // Loudness of the speech itself: the louder frames, not the pauses.
        let sorted = levels.sorted()
        let speech = sorted[Int(Double(sorted.count) * 0.85)]
        let target: Float = 0.06
        guard speech > 0.0008, speech < target * 0.6 else { return s }
        let gain = min(12, target / speech)
        return s.map { x in let y = x * gain; return abs(y) < 0.8 ? y : (y > 0 ? 1 : -1) * (0.8 + 0.2 * tanh((abs(y) - 0.8) / 0.2)) }
    }

    /// Loads any audio file as 16 kHz mono samples (used by the CLI test hook).
    static func load(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RecorderError.noInput
        }
        try file.read(into: buffer)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat),
              let samples = convert(buffer, with: converter) else { throw RecorderError.noInput }
        return samples
    }

    // MARK: - Encoding

    static func wav(from samples: [Float]) -> Data {
        let rate = UInt32(sampleRate)
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// AAC in an MP4 container: roughly 8x smaller than WAV, so long dictations upload faster.
    static func m4a(from samples: [Float]) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAAC(samples, to: url)
        return try Data(contentsOf: url)
    }

    private static func writeAAC(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { throw RecorderError.noInput }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func inputs() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    // MARK: Muting this Mac's sound while dictating

    private static func defaultOutputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Whether the speakers/headphones are muted (nil if they can't say).
    static var outputMuted: Bool? {
        get {
            guard let id = defaultOutputID() else { return nil }
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(id, &addr) else { return nil }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        }
        set {
            guard let newValue, let id = defaultOutputID() else { return }
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(id, &addr) else { return }
            var value: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }

    /// Something is playing through the speakers right now (music, a video, a call).
    static var outputIsPlaying: Bool {
        guard let id = defaultOutputID() else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// True when sound goes to headphones (the mic can't hear it, so there's no need to mute).
    static var outputIsHeadphones: Bool {
        guard let id = defaultOutputID() else { return false }
        if isBluetooth(id) { return true }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr), AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864706E // 'hdpn'
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(id))
    }

    /// The Mac's own microphone (MacBook / iMac / Studio Display), if there is one.
    static func builtInMic() -> AudioDevice? {
        inputs().first { transport($0.id) == kAudioDeviceTransportTypeBuiltIn }
    }

    // MARK: Automatic choice

    enum Kind: Int, Comparable {
        case external, builtIn, other, bluetooth, virtual, loopback   // best first
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Virtual devices that carry other apps' sound rather than a voice; never chosen automatically.
    private static let loopbackNames = ["blackhole", "loopback", "soundflower", "multi-output", "aggregate", "zoomaudiodevice",
                                        "microsoft teams audio", "ms teams audio", "background music", "audio hijack", "obs"]

    static func kind(_ device: AudioDevice) -> Kind {
        let name = device.name.lowercased()
        if loopbackNames.contains(where: name.contains) { return .loopback }
        switch transport(device.id) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .external
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .virtual
        default: return .other
        }
    }

    /// The mic Freshflo uses when you haven't picked one:
    /// 1. the macOS default, if it's a real mic (built-in, USB, an interface, or a voice tool like Krisp that you set as default);
    /// 2. otherwise (a Bluetooth headset while "use the Mac's mic" is on, or a loopback like BlackHole) the best real mic:
    ///    USB/external, then built-in, then anything else, then Bluetooth.
    static func automatic(preferBuiltIn: Bool) -> AudioDevice? {
        let all = inputs()
        if let current = defaultInputID(), let device = all.first(where: { $0.id == current }) {
            switch kind(device) {
            case .external, .builtIn, .other, .virtual: return device
            case .bluetooth where !preferBuiltIn: return device
            default: break
            }
        }
        return ranked(all, preferBuiltIn: preferBuiltIn).first
    }

    /// Real mics, best first (loopbacks excluded).
    static func ranked(_ all: [AudioDevice] = inputs(), preferBuiltIn: Bool) -> [AudioDevice] {
        all.filter { kind($0) != .loopback }.sorted { a, b in
            var ka = kind(a), kb = kind(b)
            // With "use the Mac's mic" off, a Bluetooth headset counts as good as anything else.
            if !preferBuiltIn { if ka == .bluetooth { ka = .other }; if kb == .bluetooth { kb = .other } }
            return ka < kb
        }
    }

    /// The mic to record from: the one you picked (if it's still connected), otherwise the automatic choice.
    static func preferredUID(chosen: String, preferBuiltIn: Bool) -> String {
        let all = inputs()
        if !chosen.isEmpty, all.contains(where: { $0.uid == chosen }) { return chosen }
        return automatic(preferBuiltIn: preferBuiltIn)?.uid ?? ""
    }

    /// The next mic to try when `current` delivers silence.
    static func fallback(after current: String, preferBuiltIn: Bool) -> AudioDevice? {
        ranked(preferBuiltIn: preferBuiltIn).first { $0.uid != current }
    }

    /// Calls back on the main queue whenever a mic is connected or removed, or the macOS default changes.
    static func watch(_ onChange: @escaping () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { _, _ in onChange() }
        }
    }

    /// Whether any app is currently recording from any mic (a call in progress, usually).
    static func someoneIsRecording() -> Bool {
        inputs().contains { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
