import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

enum LocalSpeechError: LocalizedError {
    case unsupportedOS
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "On-device transcription needs macOS 26"
        case .unsupportedLanguage(let code): return "On-device transcription doesn't support “\(code)”"
        }
    }
}

/// Free, offline transcription with Apple's on-device dictation model (macOS 26+).
enum LocalSpeech {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func transcribe(
        _ samples: [Float],
        language: String,
        vocabulary: [String],
        onStatus: @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        #if canImport(Speech)
        guard #available(macOS 26.0, *) else { throw LocalSpeechError.unsupportedOS }
        let transcriber = try await makeTranscriber(language: language)
        try await ensureModel(for: transcriber, onStatus: onStatus)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("excuseme-\(UUID().uuidString).wav")
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
        guard #available(macOS 26.0, *) else { throw LocalSpeechError.unsupportedOS }
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
        guard #available(macOS 26.0, *) else { return "Requires macOS 26" }
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
        guard #available(macOS 26.0, *) else { throw LocalSpeechError.unsupportedOS }
        try await ensureModel(for: try await makeTranscriber(language: language), onStatus: { _ in })
        #endif
    }

    #if canImport(Speech)
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
