import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

enum LocalSpeechError: LocalizedError {
    case unsupportedOS
    case unsupportedLanguage(String)
    case notAuthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "On-device transcription needs macOS 26"
        case .unsupportedLanguage(let code): return "Apple's speech engine doesn't support “\(code)”"
        case .notAuthorized: return "Allow Speech Recognition for Freshflo in System Settings → Privacy & Security → Speech Recognition."
        case .unavailable: return "Apple's speech engine isn't available right now. Check your internet connection, or add a free Groq key in Settings."
        }
    }
}

/// The built-in, free engine that needs no API key.
/// macOS 26+: Apple's on-device dictation model (SpeechAnalyzer).
/// macOS 14–15: the system speech recognizer, on this Mac when it supports the language, otherwise Apple's servers.
enum LocalSpeech {
    /// True when the built-in engine can work without a network connection (used for the offline fallback).
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        #if canImport(Speech)
        return legacyRecognizer(language: "")?.supportsOnDeviceRecognition ?? false
        #else
        return false
        #endif
    }

    /// Whether audio stays on this Mac with the built-in engine, for the privacy log and setup copy.
    static func runsOnDevice(language: String) -> Bool {
        if #available(macOS 26.0, *) { return true }
        #if canImport(Speech)
        return legacyRecognizer(language: language)?.supportsOnDeviceRecognition ?? false
        #else
        return false
        #endif
    }

    /// The engine name recorded in History (anything starting "apple-speech" counts as on-device).
    static func engineName(language: String) -> String {
        runsOnDevice(language: language) ? "apple-speech" : "apple-dictation (Apple servers)"
    }

    static func transcribe(
        _ samples: [Float],
        language: String,
        vocabulary: [String],
        onStatus: @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        #if canImport(Speech)
        guard #available(macOS 26.0, *), !forceLegacy else {
            return try await legacyTranscribe(samples, language: language, vocabulary: vocabulary).text
        }
        let transcriber = try await makeTranscriber(language: language)
        try await ensureModel(for: transcriber, onStatus: onStatus)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioRecorder.wav(from: samples).write(to: url)
        let file = try AVAudioFile(forReading: url)

        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }

        async let text = collect(transcriber)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true
        )
        let result = try await text
        withExtendedLifetime(analyzer) {}
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw LocalSpeechError.unsupportedOS
        #endif
    }

    /// Timestamped on-device transcription of an audio file (meeting notes).
    static func transcribeSegments(file url: URL, language: String, vocabulary: [String]) async throws -> [Transcriber.Segment] {
        #if canImport(Speech)
        guard #available(macOS 26.0, *), !forceLegacy else {
            return try await legacyTranscribe(try AudioRecorder.load(url: url), language: language, vocabulary: vocabulary).segments
        }
        let base = try await makeTranscriber(language: language)
        try await ensureModel(for: base, onStatus: { _ in })
        let transcriber = DictationTranscriber(
            locale: base.selectedLocales.first ?? Locale.current, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [], attributeOptions: [.audioTimeRange]
        )
        let file = try AVAudioFile(forReading: url)
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }
        async let segments: [Transcriber.Segment] = {
            var out: [Transcriber.Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(Transcriber.Segment(start: result.range.start.seconds, text: text)) }
            }
            return out
        }()
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true)
        let result = try await segments
        withExtendedLifetime(analyzer) {}
        return result
        #else
        throw LocalSpeechError.unsupportedOS
        #endif
    }

    /// Human-readable model state for Settings.
    static func status(language: String) async -> String {
        #if canImport(Speech)
        guard #available(macOS 26.0, *), !forceLegacy else {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .denied, .restricted: return "Speech Recognition is turned off for Freshflo"
            default: break
            }
            guard let recognizer = legacyRecognizer(language: language) else { return "Language not supported" }
            return recognizer.supportsOnDeviceRecognition ? "Ready" : "Ready (uses Apple's servers)"
        }
        guard let transcriber = try? await makeTranscriber(language: language) else { return "Language not supported" }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return "Ready"
        case .downloading: return "Downloading…"
        case .supported: return "Model not downloaded yet"
        case .unsupported: return "Not supported on this Mac"
        @unknown default: return "Unknown"
        }
        #else
        return "Requires macOS 26"
        #endif
    }

    static func downloadModel(language: String) async throws {
        #if canImport(Speech)
        guard #available(macOS 26.0, *), !forceLegacy else {
            guard await requestAuthorization() else { throw LocalSpeechError.notAuthorized }
            return
        }
        try await ensureModel(for: try await makeTranscriber(language: language), onStatus: { _ in })
        #endif
    }

    #if canImport(Speech)
    /// FRESHFLO_LEGACY_SPEECH=1 exercises the macOS 14–15 path on newer systems (CLI testing).
    static let forceLegacy = ProcessInfo.processInfo.environment["FRESHFLO_LEGACY_SPEECH"] == "1"

    static var needsAuthorization: Bool {
        if #available(macOS 26.0, *), !forceLegacy { return false }
        return SFSpeechRecognizer.authorizationStatus() != .authorized
    }

    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func legacyRecognizer(language: String) -> SFSpeechRecognizer? {
        let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
        return SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Transcribes in pieces of under a minute (Apple's server limit), cutting at the quietest moment.
    private static func legacyTranscribe(_ samples: [Float], language: String, vocabulary: [String]) async throws -> (text: String, segments: [Transcriber.Segment]) {
        guard await requestAuthorization() else { throw LocalSpeechError.notAuthorized }
        guard let recognizer = legacyRecognizer(language: language), recognizer.isAvailable else { throw LocalSpeechError.unavailable }
        var texts: [String] = []
        var segments: [Transcriber.Segment] = []
        for (offset, chunk) in chunks(samples) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioRecorder.wav(from: Array(chunk)).write(to: url)
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.contextualStrings = Array(vocabulary.prefix(100))
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            guard let transcription = try await recognize(recognizer, request) else { continue }
            texts.append(transcription.formattedString)
            // Group words into lines at pauses of 0.9 s or more, for meeting transcripts.
            var line = "", lineStart = 0.0, lastEnd = -1.0
            for segment in transcription.segments {
                if !line.isEmpty, segment.timestamp - lastEnd >= 0.9 {
                    segments.append(Transcriber.Segment(start: offset + lineStart, text: line))
                    line = ""
                }
                if line.isEmpty { lineStart = segment.timestamp }
                line += (line.isEmpty ? "" : " ") + segment.substring
                lastEnd = segment.timestamp + segment.duration
            }
            if !line.isEmpty { segments.append(Transcriber.Segment(start: offset + lineStart, text: line)) }
        }
        return (texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), segments)
    }

    private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechRecognitionRequest) async throws -> SFTranscription? {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription)
                } else if let error {
                    finished = true
                    // "No speech detected" is an empty result, not a failure.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 || code == 301 { continuation.resume(returning: nil) } else { continuation.resume(throwing: error) }
                }
            }
            _ = task
        }
    }

    /// Splits 16 kHz audio into pieces of at most 55 s, cutting at the quietest 0.3 s after the 40 s mark.
    static func chunks(_ s: [Float], maxSeconds: Double = 55, minSeconds: Double = 40) -> [(offset: Double, samples: ArraySlice<Float>)] {
        let rate = 16_000, maxLength = Int(maxSeconds * Double(rate)), minLength = Int(minSeconds * Double(rate)), window = rate * 3 / 10
        var out: [(Double, ArraySlice<Float>)] = []
        var start = 0
        while s.count - start > maxLength {
            var cut = start + maxLength, quietest = Float.infinity, i = start + minLength
            while i + window <= start + maxLength {
                var energy: Float = 0
                for j in i..<(i + window) { energy += s[j] * s[j] }
                if energy < quietest { quietest = energy; cut = i + window / 2 }
                i += window / 2
            }
            out.append((Double(start) / Double(rate), s[start..<cut]))
            start = cut
        }
        out.append((Double(start) / Double(rate), s[start..<s.count]))
        return out
    }

    @available(macOS 26.0, *)
    private static func makeTranscriber(language: String) async throws -> DictationTranscriber {
        let wanted = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw LocalSpeechError.unsupportedLanguage(language.isEmpty ? wanted.identifier : language)
        }
        return DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: []
        )
    }

    @available(macOS 26.0, *)
    private static func ensureModel(for transcriber: DictationTranscriber, onStatus: (String) -> Void) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        onStatus("Downloading speech model…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    @available(macOS 26.0, *)
    private static func collect(_ transcriber: DictationTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results {
            text += String(result.text.characters)
        }
        return text
    }
    #endif
}
