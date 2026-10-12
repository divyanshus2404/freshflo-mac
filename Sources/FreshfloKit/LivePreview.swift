import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Live words while you speak (captions), using Apple's on-device recognizer: SpeechAnalyzer on macOS 26,
/// SFSpeechRecognizer (on-device only, never Apple's servers) on macOS 14–15.
/// The final text still comes from the main engine; this is only a preview (and an instant offline fallback).
final class LivePreview {
    var onText: ((String) -> Void)?
    private var session: AnyObject?

    /// Resolves the locale and audio format ahead of time so starting a preview is instant.
    /// macOS 26's SpeechAnalyzer once its model is installed; otherwise the older on-device recognizer.
    private static var useModern: Bool {
        #if canImport(Speech)
        if #available(macOS 26.0, *) { return !LocalSpeech.forceLegacy && LivePreviewSession.isReady }
        #endif
        return false
    }

    static func prepare(language: String) {
        #if canImport(Speech)
        if #available(macOS 26.0, *), !LocalSpeech.forceLegacy {
            Task { await LivePreviewSession.prepare(language: language) }
        }
        LegacyPreviewSession.prepare(language: language)
        #endif
    }

    static var isReady: Bool {
        #if canImport(Speech)
        if useModern { return true }
        // Speech permission may have been granted since launch.
        if !LegacyPreviewSession.isReady { LegacyPreviewSession.prepare(language: AppSettings.shared.language) }
        return LegacyPreviewSession.isReady
        #else
        return false
        #endif
    }

    func start() {
        #if canImport(Speech)
        if Self.useModern, #available(macOS 26.0, *) {
            let s = LivePreviewSession()
            s.onText = { [weak self] text in self?.onText?(text) }
            if s.start() { session = s }
        } else {
            let s = LegacyPreviewSession()
            s.onText = { [weak self] text in self?.onText?(text) }
            if s.start() { session = s }
        }
        #endif
    }

    /// Called from the audio thread with 16 kHz mono samples.
    func feed(_ samples: [Float]) {
        #if canImport(Speech)
        if #available(macOS 26.0, *), let s = session as? LivePreviewSession { s.feed(samples); return }
        (session as? LegacyPreviewSession)?.feed(samples)
        #endif
    }

    /// Ends the preview and returns the best text it heard.
    @discardableResult
    func stop() -> String {
        #if canImport(Speech)
        defer { session = nil }
        if #available(macOS 26.0, *), let s = session as? LivePreviewSession { return s.stop() }
        if let s = session as? LegacyPreviewSession { return s.stop() }
        #endif
        return ""
    }
}

#if canImport(Speech)
/// macOS 14–15: Apple's older recognizer with partial results. Only runs when the language works on-device,
/// so captions never send audio anywhere.
private final class LegacyPreviewSession: @unchecked Sendable {
    private static let stateLock = NSLock()
    private static var recognizer: SFSpeechRecognizer?

    static var isReady: Bool { stateLock.withLock { recognizer != nil } }

    static func prepare(language: String) {
        var ready: SFSpeechRecognizer?
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
            if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition, r.isAvailable { ready = r }
        }
        stateLock.withLock { recognizer = ready }
    }

    var onText: ((String) -> Void)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var latest = ""

    func start() -> Bool {
        guard let recognizer = Self.stateLock.withLock({ Self.recognizer }) else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.lock.withLock { self.latest = text }
            DispatchQueue.main.async { self.onText?(text) }
        }
        return true
    }

    func feed(_ samples: [Float]) {
        guard let request, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        request.append(buffer)
    }

    func stop() -> String {
        request?.endAudio()
        request = nil
        let task = self.task
        self.task = nil
        // Let the recognizer settle its last words, then free it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { task?.cancel() }
        return lock.withLock { latest }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

#if canImport(Speech)
@available(macOS 26.0, *)
private final class LivePreviewSession: @unchecked Sendable {
    private static let stateLock = NSLock()
    private static var locale: Locale?
    private static var format: AVAudioFormat?

    static var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return locale != nil && format != nil
    }

    static func prepare(language: String) async {
        let wanted = language.isEmpty ? Locale.current : Locale(identifier: language)
        var readyLocale: Locale?
        var readyFormat: AVAudioFormat?
        if let resolved = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let probe = makeTranscriber(resolved)
            // Never trigger a model download mid-dictation; preview only runs once the model is installed.
            if await AssetInventory.status(forModules: [probe]) == .installed {
                readyFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
                readyLocale = resolved
            }
        }
        stateLock.withLock {
            locale = readyLocale
            format = readyFormat
        }
    }

    private static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults], attributeOptions: []
        )
    }

    var onText: ((String) -> Void)?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var finalText = ""
    private var volatileText = ""

    func start() -> Bool {
        Self.stateLock.lock()
        let locale = Self.locale, format = Self.format
        Self.stateLock.unlock()
        guard let locale, let format else { return false }

        let transcriber = Self.makeTranscriber(locale)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation
        targetFormat = format
        converter = format == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        Task { try? await analyzer.start(inputSequence: stream) }
        Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let combined = self.lock.withLock {
                        if result.isFinal {
                            self.finalText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        return (self.finalText + self.volatileText).trimmingCharacters(in: .whitespaces)
                    }
                    DispatchQueue.main.async { self.onText?(combined) }
                }
            } catch {}
        }
        return true
    }

    func feed(_ samples: [Float]) {
        guard let continuation, let targetFormat, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }

        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * targetFormat.sampleRate / sourceFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
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
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() -> String {
        continuation?.finish()
        continuation = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        lock.lock(); defer { lock.unlock() }
        return (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
