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
    /// When false, audio is only streamed through `onChunk` (long meetings would otherwise fill memory).
    var retainSamples = true
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var peak: Float = 0

    /// Loudest sample so far; ~0 means the mic is delivering silence (muted or dead device).
    var peakSoFar: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    /// Reused between recordings: building a new engine each time added ~100 ms before the mic was live.
    /// It's thrown away when the device changes (AirPods connect) or the user picks a different mic.
    private var reusableEngine: AVAudioEngine?
    private var reusableDeviceUID: String?
    private var configObserver: NSObjectProtocol?

    private func makeEngine() -> AVAudioEngine {
        if let engine = reusableEngine, reusableDeviceUID == deviceUID { return engine }
        let engine = AVAudioEngine()
        if !deviceUID.isEmpty, let device = AudioDevices.deviceID(forUID: deviceUID), let unit = engine.inputNode.audioUnit {
            var id = device
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.reusableEngine = nil
        }
        reusableEngine = engine
        reusableDeviceUID = deviceUID
        return engine
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
        lock.lock(); samples.removeAll(keepingCapacity: true); peak = 0; lock.unlock()
        let engine = makeEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: Self.targetFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A stale reused engine can fail after device changes; retry once with a fresh one.
            input.removeTap(onBus: 0)
            reusableEngine = nil
            let fresh = makeEngine()
            let freshFormat = fresh.inputNode.outputFormat(forBus: 0)
            guard freshFormat.sampleRate > 0 else { throw RecorderError.noInput }
            converter = AVAudioConverter(from: freshFormat, to: Self.targetFormat)
            fresh.inputNode.installTap(onBus: 0, bufferSize: 2048, format: freshFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            fresh.prepare()
            try fresh.start()
            self.engine = fresh
            isRecording = true
            return
        }
        self.engine = engine
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording, let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let chunk = Self.convert(buffer, with: converter) else { return }
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(1, max(0, (db + 55) / 45))

        lock.lock(); if retainSamples { samples.append(contentsOf: chunk) }; peak = max(peak, chunk.map(abs).max() ?? 0); lock.unlock()
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

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
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
        let threshold = max(0.0025, noiseFloor * 3)
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
