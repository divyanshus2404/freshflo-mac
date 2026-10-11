import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Streams 16 kHz mono samples into a compact AAC file on its own queue.
final class ChunkWriter {
    private var file: AVAudioFile?
    private let queue: DispatchQueue
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var peak: Float = 0
    private(set) var frames: Int = 0

    init(url: URL, label: String) throws {
        queue = DispatchQueue(label: "ExcuseMe.writer.\(label)")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
            try? file.write(from: buffer)
            peak = max(peak, samples.map(abs).max() ?? 0)
            frames += samples.count
        }
    }

    /// Flushes and closes the file.
    func close() {
        queue.sync { file = nil }
    }
}

enum MeetingRecorderError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "Couldn't access system audio" }
}

/// Records the meeting as two separate tracks: your microphone ("You") and everything your Mac plays ("Them").
/// Separate tracks give speaker labels for free, without a diarization model.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isRecording = false
    private(set) var startedAt = Date()
    private(set) var capturesSystemAudio = false

    private let mic = AudioRecorder()
    private var micWriter: ChunkWriter?
    private var systemWriter: ChunkWriter?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "ExcuseMe.meeting.system")

    func start(folder: URL, micDeviceUID: String) async throws {
        micWriter = try ChunkWriter(url: folder.appendingPathComponent("you.m4a"), label: "mic")
        systemWriter = try ChunkWriter(url: folder.appendingPathComponent("them.m4a"), label: "system")

        mic.retainSamples = false
        mic.deviceUID = micDeviceUID
        mic.onChunk = { [weak self] chunk in self?.micWriter?.write(chunk) }
        try mic.start()

        // System audio needs the Screen Recording permission; without it we still record your side.
        do {
            try await startSystemAudio()
            capturesSystemAudio = true
        } catch {
            capturesSystemAudio = false
        }
        startedAt = Date()
        isRecording = true
    }

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw MeetingRecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // Video is unavoidable with SCStream; keep it tiny and slow so it costs nothing.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops both tracks; returns whether each track contains real sound.
    func stop() async -> (micHasAudio: Bool, systemHasAudio: Bool) {
        guard isRecording else { return (false, false) }
        isRecording = false
        _ = mic.stop()
        mic.onChunk = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        micWriter?.close()
        systemWriter?.close()
        let result = ((micWriter?.peak ?? 0) > 0.01, (systemWriter?.peak ?? 0) > 0.01)
        micWriter = nil
        systemWriter = nil
        return result
    }

    var micLevel: Float { mic.peakSoFar }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let samples = Self.floats(from: sampleBuffer) else { return }
        systemWriter?.write(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        capturesSystemAudio = false
    }

    /// Extracts mono Float32 samples (averaging channels if the system delivers more than one).
    private static func floats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        if buffers.count == 1 {
            let channels = max(1, Int(first.mNumberChannels))
            let all = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frameCount)
            guard channels > 1 else { return Array(all) }
            return stride(from: 0, to: frameCount - channels + 1, by: channels).map { i in
                (0..<channels).reduce(Float(0)) { $0 + all[i + $1] } / Float(channels)
            }
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for buffer in buffers {
            guard let d = buffer.mData else { continue }
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount { mono[i] += p[i] }
        }
        let n = Float(buffers.count)
        return mono.map { $0 / n }
    }
}
