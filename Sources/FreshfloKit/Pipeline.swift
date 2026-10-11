import Foundation

struct Transcript {
    var text: String
    var engine: String
}

/// The audio → text steps shared by live dictation and the CLI test hook.
@MainActor
enum Pipeline {
    static func transcribe(
        _ samples: [Float],
        settings: AppSettings,
        forceLocal: Bool = false,
        extraVocabulary: [String] = [],
        liveFallback: String = "",
        onStatus: @escaping (String) -> Void = { _ in }
    ) async throws -> Transcript {
        let vocabulary = settings.dictionary + extraVocabulary
        if forceLocal || settings.provider == .local {
            let text = try await LocalSpeech.transcribe(samples, language: settings.language, vocabulary: vocabulary, onStatus: onStatus)
            return Transcript(text: text, engine: "apple-speech")
        }
        do {
            let text = try await Transcriber.transcribe(samples: samples, endpoint: settings.endpoint, vocabulary: vocabulary)
            return Transcript(text: Transcriber.stripHallucinations(text), engine: settings.endpoint.transcriptionModel)
        } catch {
            guard settings.offlineFallback, Transcriber.isNetworkError(error) else { throw error }
            // The live preview already heard everything on-device; use it instead of re-transcribing.
            if !liveFallback.isEmpty { return Transcript(text: liveFallback, engine: "apple-speech (live, offline fallback)") }
            guard LocalSpeech.isSupported else { throw error }
            onStatus("Offline: transcribing on device…")
            let text = try await LocalSpeech.transcribe(samples, language: settings.language, vocabulary: vocabulary, onStatus: onStatus)
            return Transcript(text: text, engine: "apple-speech (offline fallback)")
        }
    }

    static func polish(raw: String, context: FocusContext, settings: AppSettings,
                       mode: CleanupMode? = nil, extraVocabulary: [String] = [], longForm: Bool = false) async -> CleanupResult {
        let snippets = settings.snippets
        if let expansion = SnippetExpander.wholeMatch(raw, snippets: snippets) {
            return CleanupResult(text: expansion, engine: "snippet")
        }
        let input = CleanupInput(
            raw: raw,
            tone: settings.tone(for: context.bundleID),
            context: context,
            vocabulary: settings.dictionary + extraVocabulary,
            keepPhrases: snippets.map(\.trigger).filter { !$0.isEmpty },
            customInstructions: settings.customInstructions,
            outputLanguage: settings.outputLanguage,
            regional: settings.regionalFormat,
            longForm: longForm
        )
        var result = await Cleanup.run(input, mode: mode ?? settings.cleanupMode, endpoint: settings.endpoint, canUseAPI: settings.canUseCloud)
        result.text = SnippetExpander.applyInline(result.text, snippets: snippets)
        return result
    }

    static func command(instruction: String, selection: String?, context: FocusContext, settings: AppSettings) async throws -> String {
        try await Command.run(
            instruction: instruction,
            selection: selection,
            context: context,
            endpoint: settings.endpoint,
            canUseAPI: settings.canUseCloud,
            vocabulary: settings.dictionary,
            customInstructions: settings.customInstructions
        )
    }
}
