import Foundation

struct Transcript {
    var text: String
    var engine: String
    /// The spoken language, as best Freshflo can tell.
    var language: LanguageID.Detection? = nil
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
        // Your own words first, then the people you meet with most (transcription prompts are short).
        let vocabulary = settings.dictionary + extraVocabulary + settings.knownNames.prefix(30)
        if forceLocal || !settings.provider.transcribesInCloud {
            OnDeviceWhisper.lastLanguage = nil
            let text = try await LocalSpeech.transcribe(samples, language: settings.language, vocabulary: vocabulary, onStatus: onStatus)
            let detected = LanguageID.detect(text: text, whisperGuess: OnDeviceWhisper.isActive ? OnDeviceWhisper.lastLanguage : (settings.language.isEmpty ? nil : settings.language),
                                             hints: settings.spokenLanguages)
            return Transcript(text: text, engine: LocalSpeech.engineName(language: settings.language), language: detected)
        }
        do {
            Transcriber.lastLanguage = nil
            var text = Transcriber.stripHallucinations(try await Transcriber.transcribe(samples: samples, endpoint: settings.endpoint, vocabulary: vocabulary))
            let hints = settings.spokenLanguages
            var detected = LanguageID.detect(text: text, whisperGuess: Transcriber.lastLanguage, hints: hints)
            if Cleanup.debug { print("debug heard [\(settings.endpoint.transcriptionModel), \(Transcriber.lastLanguage ?? "?")→\(detected?.code ?? "?")]: \(text)") }
            // Whisper's language guess looks wrong (common on short or accented clips): try your other language and keep
            // whichever reads more like its language.
            if settings.language.isEmpty, LanguageID.shouldRetry(text: text, detected: detected?.code, hints: hints),
               let yours = LanguageID.alternative(text: text, detected: detected?.code, hints: hints) {
                var forced = Self.carefulEndpoint(settings.endpoint)
                forced.language = yours
                if let again = try? await Transcriber.transcribe(samples: samples, endpoint: forced, vocabulary: vocabulary), !again.isEmpty {
                    let candidate = Transcriber.stripHallucinations(again)
                    let before = LanguageID.confidence(text, is: detected?.code ?? "en")
                    let after = max(LanguageID.confidence(candidate, is: yours), yours == "hi" && LanguageID.isHinglish(candidate) ? 1 : 0)
                    // Heard as a language you don't speak: a solid result in yours wins even if the first reads "surer".
                    let outsider = detected.map { !hints.contains($0.code) && LanguageID.indianNeighbours($0.code, hints) } ?? false
                    if Cleanup.debug { print("debug re-heard as \(yours) [\(forced.transcriptionModel)] before \(before) after \(after): \(candidate)") }
                    if after >= before || (outsider && after >= 0.5) {
                        text = candidate
                        detected = LanguageID.Detection(code: yours, hinglish: yours == "hi" && LanguageID.isHinglish(text))
                    }
                }
            }
            // Right language, wrong script (Hindi in Urdu letters, say): transcribe again with the language named,
            // which also gives Whisper a sample sentence in the right script.
            if let code = detected?.code, detected?.hinglish != true, Indic.wrongScript(text, lang: code) {
                var forced = Self.carefulEndpoint(settings.endpoint)
                forced.language = code
                if let again = try? await Transcriber.transcribe(samples: samples, endpoint: forced, vocabulary: vocabulary),
                   !again.isEmpty, !Indic.wrongScript(again, lang: code) {
                    if Cleanup.debug { print("debug script fix as \(code): \(again)") }
                    text = Transcriber.stripHallucinations(again)
                }
            }
            return Transcript(text: text, engine: settings.endpoint.transcriptionModel, language: detected)
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

    /// For a second listen: Groq's full Whisper model instead of turbo. A little slower, and much better at
    /// Bengali, Telugu, Kannada and other languages turbo tends to mistake for Hindi or Tamil.
    nonisolated static func carefulEndpoint(_ endpoint: ProviderEndpoint) -> ProviderEndpoint {
        var e = endpoint
        if e.transcriptionModel == "whisper-large-v3-turbo" { e.transcriptionModel = "whisper-large-v3" }
        return e
    }

    static func polish(raw: String, context: FocusContext, settings: AppSettings,
                       mode: CleanupMode? = nil, extraVocabulary: [String] = [], longForm: Bool = false) async -> CleanupResult {
        let snippets = settings.snippets
        if let expansion = SnippetExpander.wholeMatch(raw, snippets: snippets) {
            return CleanupResult(text: expansion, engine: "snippet")
        }
        let input = CleanupInput(
            raw: raw,
            tone: settings.tone(for: context),
            context: context,
            vocabulary: settings.dictionary + extraVocabulary + settings.knownNames,
            keepPhrases: snippets.map(\.trigger).filter { !$0.isEmpty },
            customInstructions: settings.customInstructions,
            // Already in that language (and not Hinglish): normal cleanup, whose checks keep your exact words.
            outputLanguage: LanguageID.alreadyIn(raw, target: settings.outputLanguage) ? "" : settings.outputLanguage,
            regional: settings.regionalFormat,
            longForm: longForm,
            profanity: settings.profanity,
            fixGrammar: settings.fixGrammar,
            smartLists: settings.smartLists,
            emailMode: settings.emailFormatting && EmailFormat.isMailTarget(bundleID: context.bundleID, windowTitle: context.windowTitle)
        )
        var result = await Cleanup.run(input, mode: mode ?? settings.cleanupMode, endpoint: settings.endpoint, canUseAPI: settings.canUseCloud)
        // "Write in": make sure it really came out in that language (and script); if not, translate once more, strictly.
        if input.translating, !LanguageID.matches(result.text, target: input.outputLanguage),
           let strict = await Cleanup.translateStrict(result.text.isEmpty ? raw : result.text, original: raw, to: input.outputLanguage, settings: settings) {
            result = CleanupResult(text: TextPolish.apply(strict, input.polish), engine: result.engine + "+verified")
        }
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
