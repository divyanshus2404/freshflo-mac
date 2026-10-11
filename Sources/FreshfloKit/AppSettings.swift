import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private var reloading = false

    @Published var hotkey: HotkeyKey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }

    @Published var provider: Provider {
        didSet {
            defaults.set(provider.rawValue, forKey: "provider")
            reloading = true
            apiKey = Keychain.get(provider.rawValue)
            baseURL = defaults.string(forKey: "baseURL.\(provider.rawValue)") ?? provider.defaultBaseURL
            transcriptionModel = defaults.string(forKey: "transcriptionModel.\(provider.rawValue)") ?? provider.defaultTranscriptionModel
            cleanupModel = defaults.string(forKey: "cleanupModel.\(provider.rawValue)") ?? provider.defaultCleanupModel
            smartModel = defaults.string(forKey: "smartModel.\(provider.rawValue)") ?? provider.defaultSmartModel
            reloading = false
        }
    }

    @Published var apiKey: String {
        didSet { if !reloading { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.rawValue) } }
    }
    @Published var baseURL: String {
        didSet { if !reloading { defaults.set(baseURL, forKey: "baseURL.\(provider.rawValue)") } }
    }
    @Published var transcriptionModel: String {
        didSet { if !reloading { defaults.set(transcriptionModel, forKey: "transcriptionModel.\(provider.rawValue)") } }
    }
    @Published var cleanupModel: String {
        didSet { if !reloading { defaults.set(cleanupModel, forKey: "cleanupModel.\(provider.rawValue)") } }
    }
    @Published var smartModel: String {
        didSet { if !reloading { defaults.set(smartModel, forKey: "smartModel.\(provider.rawValue)") } }
    }

    /// ISO-639-1 code, or empty for automatic detection.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: "cleanupMode") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var addTrailingSpace: Bool { didSet { defaults.set(addTrailingSpace, forKey: "addTrailingSpace") } }
    @Published var defaultTone: Tone { didSet { defaults.set(defaultTone.rawValue, forKey: "defaultTone") } }
    @Published var toneRules: [AppToneRule] { didSet { save(toneRules, "toneRules") } }
    @Published var snippets: [Snippet] { didSet { save(snippets, "snippets") } }
    /// Names and jargon to bias transcription and cleanup toward.
    @Published var dictionary: [String] { didSet { save(dictionary, "dictionary") } }
    /// CoreAudio device UID, or empty for the system default input.
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var commandModeEnabled: Bool { didSet { defaults.set(commandModeEnabled, forKey: "commandModeEnabled") } }
    @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: "useScreenContext") } }
    @Published var offlineFallback: Bool { didSet { defaults.set(offlineFallback, forKey: "offlineFallback") } }
    @Published var livePreview: Bool { didSet { defaults.set(livePreview, forKey: "livePreview") } }
    /// Language to write in regardless of the spoken language (empty = same as spoken).
    @Published var outputLanguage: String { didSet { defaults.set(outputLanguage, forKey: "outputLanguage") } }
    @Published var regionalFormat: RegionalFormat { didSet { defaults.set(regionalFormat.rawValue, forKey: "regionalFormat") } }
    @Published var indicatorStyle: IndicatorStyle { didSet { defaults.set(indicatorStyle.rawValue, forKey: "indicatorStyle") } }
    @Published var indicatorTheme: IndicatorTheme { didSet { defaults.set(indicatorTheme.rawValue, forKey: "indicatorTheme") } }
    /// Swear words: clean up (default), mask, or keep.
    @Published var profanity: ProfanityMode { didSet { defaults.set(profanity.rawValue, forKey: "profanity") } }
    /// Make dictations grammatically correct, not just punctuated.
    @Published var fixGrammar: Bool { didSet { defaults.set(fixGrammar, forKey: "fixGrammar") } }
    @Published var indicatorPosition: IndicatorPosition { didSet { defaults.set(indicatorPosition.rawValue, forKey: "indicatorPosition") } }
    @Published var soundTheme: SoundTheme { didSet { defaults.set(soundTheme.rawValue, forKey: "soundTheme") } }
    @Published var askModeEnabled: Bool { didSet { defaults.set(askModeEnabled, forKey: "askModeEnabled") } }
    @Published var keepMeetingAudio: Bool { didSet { defaults.set(keepMeetingAudio, forKey: "keepMeetingAudio") } }
    @Published var autoLearn: Bool { didSet { defaults.set(autoLearn, forKey: "autoLearn") } }
    /// Free-form style rules applied to every cleanup and command ("Use British spelling").
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }

    private init() {
        let d = UserDefaults.standard
        let provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? (Keychain.get(Provider.groq.rawValue).isEmpty ? .local : .groq)
        self.provider = provider
        hotkey = HotkeyKey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn
        apiKey = Keychain.get(provider.rawValue)
        baseURL = d.string(forKey: "baseURL.\(provider.rawValue)") ?? provider.defaultBaseURL
        transcriptionModel = d.string(forKey: "transcriptionModel.\(provider.rawValue)") ?? provider.defaultTranscriptionModel
        // Faster default cleanup model (v1.1): drop the old auto-saved defaults so the new one applies.
        if !d.bool(forKey: "migrated.fastCleanup") {
            d.set(true, forKey: "migrated.fastCleanup")
            let old = d.string(forKey: "cleanupModel.groq")
            if old == "openai/gpt-oss-20b" || old == "llama-3.3-70b-versatile" { d.removeObject(forKey: "cleanupModel.groq") }
        }
        cleanupModel = d.string(forKey: "cleanupModel.\(provider.rawValue)") ?? provider.defaultCleanupModel
        smartModel = d.string(forKey: "smartModel.\(provider.rawValue)") ?? provider.defaultSmartModel
        language = d.string(forKey: "language") ?? ""
        // v1.0 changed the default from Apple-only to Auto; move users who still have the old default.
        if !d.bool(forKey: "migrated.autoCleanup") {
            d.set(true, forKey: "migrated.autoCleanup")
            if d.string(forKey: "cleanupMode") == CleanupMode.apple.rawValue { d.removeObject(forKey: "cleanupMode") }
        }
        cleanupMode = CleanupMode(rawValue: d.string(forKey: "cleanupMode") ?? "") ?? .auto
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        addTrailingSpace = d.object(forKey: "addTrailingSpace") as? Bool ?? true
        defaultTone = Tone(rawValue: d.string(forKey: "defaultTone") ?? "") ?? .casual
        toneRules = Self.load("toneRules") ?? Self.defaultToneRules
        let loadedSnippets: [Snippet] = Self.load("snippets") ?? Self.defaultSnippets
        snippets = loadedSnippets.filter {
            !(Self.legacyPlaceholderTriggers.contains($0.trigger) && ($0.expansion == "you@example.com" || $0.expansion.hasSuffix("Your Name")))
        }
        dictionary = Self.load("dictionary") ?? []
        inputDeviceUID = d.string(forKey: "inputDeviceUID") ?? ""
        commandModeEnabled = d.object(forKey: "commandModeEnabled") as? Bool ?? true
        useScreenContext = d.object(forKey: "useScreenContext") as? Bool ?? true
        offlineFallback = d.object(forKey: "offlineFallback") as? Bool ?? true
        autoLearn = d.object(forKey: "autoLearn") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        keepMeetingAudio = d.object(forKey: "keepMeetingAudio") as? Bool ?? false
        askModeEnabled = d.object(forKey: "askModeEnabled") as? Bool ?? true
        indicatorStyle = IndicatorStyle(rawValue: d.string(forKey: "indicatorStyle") ?? "") ?? .halo
        indicatorTheme = IndicatorTheme(rawValue: d.string(forKey: "indicatorTheme") ?? "") ?? .fresh
        profanity = ProfanityMode(rawValue: d.string(forKey: "profanity") ?? "") ?? .cleanUp
        fixGrammar = d.object(forKey: "fixGrammar") as? Bool ?? true
        indicatorPosition = IndicatorPosition(rawValue: d.string(forKey: "indicatorPosition") ?? "") ?? .caret
        soundTheme = SoundTheme(rawValue: d.string(forKey: "soundTheme") ?? "") ?? ((d.object(forKey: "playSounds") as? Bool ?? true) ? .chimes : .off)
        outputLanguage = d.string(forKey: "outputLanguage") ?? ""
        regionalFormat = RegionalFormat(rawValue: d.string(forKey: "regionalFormat") ?? "")
            ?? (Locale.current.region?.identifier == "IN" ? .india : .none)
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        ModelResolver.onResolved = { kind, model in
            DispatchQueue.main.async {
                switch kind {
                case .chat: AppSettings.shared.cleanupModel = model
                case .transcription: AppSettings.shared.transcriptionModel = model
                }
            }
        }
    }

    func tone(for bundleID: String?) -> Tone {
        guard let bundleID else { return defaultTone }
        return toneRules.first { $0.bundleID == bundleID }?.tone ?? defaultTone
    }

    /// A cloud provider is selected and has credentials (custom servers may not need a key).
    var canUseCloud: Bool {
        provider.isCloud && (provider == .custom || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Whether a dictation can be transcribed with the current settings.
    var isReady: Bool { provider == .local || canUseCloud }

    var hasAPIKey: Bool { canUseCloud }

    func learn(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !dictionary.contains(where: { $0 == w }) else { return false }
        dictionary.removeAll { $0.caseInsensitiveCompare(w) == .orderedSame }
        dictionary.append(w)
        return true
    }

    var endpoint: ProviderEndpoint {
        ProviderEndpoint(
            baseURL: baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptionModel: transcriptionModel.trimmingCharacters(in: .whitespaces),
            cleanupModel: cleanupModel.trimmingCharacters(in: .whitespaces),
            smartModel: smartModel.trimmingCharacters(in: .whitespaces),
            language: language.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static let defaultToneRules: [AppToneRule] = [
        AppToneRule(bundleID: "com.apple.mail", appName: "Mail", tone: .formal),
        AppToneRule(bundleID: "com.microsoft.Outlook", appName: "Microsoft Outlook", tone: .formal),
        AppToneRule(bundleID: "com.microsoft.Word", appName: "Microsoft Word", tone: .formal),
        AppToneRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .casual),
        AppToneRule(bundleID: "com.apple.MobileSMS", appName: "Messages", tone: .veryCasual),
        AppToneRule(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", tone: .veryCasual),
        AppToneRule(bundleID: "com.hnc.Discord", appName: "Discord", tone: .veryCasual),
    ]

    /// Placeholder examples shipped in early builds; natural phrases like "my email" hijacked real sentences.
    private static let legacyPlaceholderTriggers: Set<String> = ["my email", "sign off"]
    static let defaultSnippets: [Snippet] = []
}

struct ProviderEndpoint {
    var baseURL: String
    var apiKey: String
    var transcriptionModel: String
    var cleanupModel: String
    var smartModel: String = ""
    var language: String

    /// The same endpoint, but chat calls use the stronger model.
    var smart: ProviderEndpoint {
        var copy = self
        if !smartModel.isEmpty { copy.cleanupModel = smartModel }
        return copy
    }
}
