import Foundation

/// Prompt mode: when you dictate into an AI tool, Freshflo writes a clear, structured prompt instead of a chat message.
/// It turns on by itself in AI apps, AI chat sites in the browser, and terminals running an AI coding agent,
/// unless the user picked a style for that app in Settings.
enum PromptMode {
    /// Desktop apps that are mainly AI chats or AI-first editors.
    static let aiApps: Set<String> = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.anthropic.claudefordesktop",  // Claude
        "com.openai.chat",                 // ChatGPT
        "com.exafunction.windsurf",        // Windsurf
        "ai.perplexity.mac",               // Perplexity
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "co.zeit.hyper",
    ]
    /// Tab titles of AI chat sites.
    private static let aiSites = try! NSRegularExpression(
        pattern: #"\b(ChatGPT|Claude|Gemini|Perplexity|Grok|DeepSeek|Copilot|Mistral|Le Chat|Lovable|v0|bolt\.new|Replit)\b"#, options: [.caseInsensitive])
    /// Window titles of terminals running an AI coding agent.
    private static let aiAgents = try! NSRegularExpression(
        pattern: #"\b(claude|claude code|codex|gemini|aider|opencode|amp|goose)\b"#, options: [.caseInsensitive])

    /// True when the focused app or tab is an AI tool.
    static func isAITarget(bundleID: String, windowTitle: String) -> Bool {
        if aiApps.contains(bundleID) { return true }
        let range = NSRange(windowTitle.startIndex..., in: windowTitle)
        if browsers.contains(bundleID) { return aiSites.firstMatch(in: windowTitle, range: range) != nil }
        if terminals.contains(bundleID) { return aiAgents.firstMatch(in: windowTitle, range: range) != nil }
        return false
    }

    /// Extra guidance and an example, added to the cleanup prompt when the tone is Prompt.
    static let example = """
    Example for Prompt style:
    <transcript>okay so um I need you to fix the login page it breaks when the token expires so add a refresh flow and uh also write tests for it and don't touch the auth middleware file</transcript>
    Fix the login page: it breaks when the token expires.
    - Add a token refresh flow.
    - Write tests for it.
    - Don't touch the auth middleware file.
    """
}

/// Languages offered in Settings: Whisper's full set of ~100. "Write in" can translate between them.
enum Languages {
    /// (code for speech recognition, display name)
    static let spoken: [(code: String, name: String)] = [
        ("", "Detect automatically"),
        ("en", "English"),
        ("hi", "Hindi"),
        ("bn", "Bengali"),
        ("mr", "Marathi"),
        ("ta", "Tamil"),
        ("te", "Telugu"),
        ("gu", "Gujarati"),
        ("kn", "Kannada"),
        ("ml", "Malayalam"),
        ("pa", "Punjabi"),
        ("ur", "Urdu"),
        ("ne", "Nepali"),
        ("si", "Sinhala"),
        ("as", "Assamese"),
        ("sa", "Sanskrit"),
        ("sd", "Sindhi"),
        ("af", "Afrikaans"),
        ("sq", "Albanian"),
        ("am", "Amharic"),
        ("ar", "Arabic"),
        ("hy", "Armenian"),
        ("az", "Azerbaijani"),
        ("ba", "Bashkir"),
        ("eu", "Basque"),
        ("be", "Belarusian"),
        ("bs", "Bosnian"),
        ("br", "Breton"),
        ("bg", "Bulgarian"),
        ("yue", "Cantonese"),
        ("ca", "Catalan"),
        ("zh", "Chinese"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("et", "Estonian"),
        ("fo", "Faroese"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("gl", "Galician"),
        ("ka", "Georgian"),
        ("de", "German"),
        ("el", "Greek"),
        ("ht", "Haitian Creole"),
        ("ha", "Hausa"),
        ("haw", "Hawaiian"),
        ("he", "Hebrew"),
        ("hu", "Hungarian"),
        ("is", "Icelandic"),
        ("id", "Indonesian"),
        ("ga", "Irish"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("jw", "Javanese"),
        ("kk", "Kazakh"),
        ("km", "Khmer"),
        ("ko", "Korean"),
        ("lo", "Lao"),
        ("la", "Latin"),
        ("lv", "Latvian"),
        ("ln", "Lingala"),
        ("lt", "Lithuanian"),
        ("lb", "Luxembourgish"),
        ("mk", "Macedonian"),
        ("mg", "Malagasy"),
        ("ms", "Malay"),
        ("mt", "Maltese"),
        ("mi", "Maori"),
        ("mn", "Mongolian"),
        ("my", "Myanmar (Burmese)"),
        ("no", "Norwegian"),
        ("nn", "Norwegian Nynorsk"),
        ("oc", "Occitan"),
        ("ps", "Pashto"),
        ("fa", "Persian"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sr", "Serbian"),
        ("sn", "Shona"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("so", "Somali"),
        ("es", "Spanish"),
        ("su", "Sundanese"),
        ("sw", "Swahili"),
        ("sv", "Swedish"),
        ("tl", "Tagalog"),
        ("tg", "Tajik"),
        ("tt", "Tatar"),
        ("th", "Thai"),
        ("bo", "Tibetan"),
        ("tr", "Turkish"),
        ("tk", "Turkmen"),
        ("uk", "Ukrainian"),
        ("uz", "Uzbek"),
        ("vi", "Vietnamese"),
        ("cy", "Welsh"),
        ("yi", "Yiddish"),
        ("yo", "Yoruba"),
        ("zu", "Zulu"),
    ]
    /// Output language names, as the model is told them ("" = same as spoken).
    /// The few you switch between, in order: Same as spoken → English → the other language you speak.
    static func quick(spoken: [String], current: String) -> [String] {
        var list = ["", "English"]
        if spoken.contains("hi") { list += ["Hindi", "Hinglish (Hindi in Latin letters)"] }
        for code in spoken where code != "en" && code != "hi" {
            if let name = written.first(where: { LanguageID.writtenCode($0) == code }) { list.append(name) }
        }
        if !list.contains(current) { list.append(current) }
        return list
    }

    /// The next one in the quick list, for the switch shortcut.
    static func next(after current: String, spoken: [String]) -> String {
        let list = quick(spoken: spoken, current: current)
        let i = list.firstIndex(of: current) ?? 0
        return list[(i + 1) % list.count]
    }

    static func label(_ written: String) -> String { written.isEmpty ? "Same as spoken" : written }

    static let written: [String] = [
        "",
        "English",
        "Hindi",
        "Hinglish (Hindi in Latin letters)",
        "Bengali",
        "Marathi",
        "Tamil",
        "Telugu",
        "Gujarati",
        "Kannada",
        "Malayalam",
        "Punjabi",
        "Urdu",
        "Nepali",
        "Arabic",
        "Chinese (Simplified)",
        "Chinese (Traditional)",
        "Czech",
        "Danish",
        "Dutch",
        "Finnish",
        "French",
        "German",
        "Greek",
        "Hebrew",
        "Hungarian",
        "Indonesian",
        "Italian",
        "Japanese",
        "Korean",
        "Malay",
        "Norwegian",
        "Persian",
        "Polish",
        "Portuguese",
        "Romanian",
        "Russian",
        "Spanish",
        "Swahili",
        "Swedish",
        "Tagalog",
        "Thai",
        "Turkish",
        "Ukrainian",
        "Vietnamese",
    ]
}
