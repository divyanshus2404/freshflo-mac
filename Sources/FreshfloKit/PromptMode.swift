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

/// Languages offered in Settings. Whisper recognizes all of these; "Write in" can translate between them.
enum Languages {
    /// (code for speech recognition, display name)
    static let spoken: [(code: String, name: String)] = [
        ("", "Detect automatically"), ("en", "English"), ("hi", "Hindi"), ("bn", "Bengali"), ("mr", "Marathi"), ("ta", "Tamil"),
        ("te", "Telugu"), ("gu", "Gujarati"), ("kn", "Kannada"), ("ml", "Malayalam"), ("pa", "Punjabi"), ("ur", "Urdu"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"), ("it", "Italian"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("ru", "Russian"), ("id", "Indonesian"), ("tr", "Turkish"),
    ]
    /// Output language names, as the model is told them ("" = same as spoken).
    static let written: [String] = [
        "", "English", "Hindi", "Hinglish (Hindi in Latin letters)", "Bengali", "Marathi", "Tamil", "Telugu", "Gujarati", "Kannada",
        "Malayalam", "Punjabi", "Urdu", "Spanish", "French", "German", "Portuguese", "Italian", "Japanese", "Korean", "Chinese", "Arabic",
    ]
}
