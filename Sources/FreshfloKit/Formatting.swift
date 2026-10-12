import Foundation

/// Email mode: in mail apps, "Hi Marcus can you … thanks Divyanshu" becomes a greeting line, the body, and a sign-off block.
enum EmailFormat {
    static let mailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "it.bloop.airmail2",
        "com.freron.MailMate", "com.mimestream.Mimestream", "com.google.Chrome.app.Gmail", "com.canarymail.mac", "com.edisonmail.edisonmail",
    ]
    private static let mailTabs = try! NSRegularExpression(pattern: #"\b(Gmail|Outlook|Inbox|Mail\b|Proton Mail|Yahoo Mail|Zoho Mail|Superhuman)"#, options: [.caseInsensitive])

    static func isMailTarget(bundleID: String, windowTitle: String) -> Bool {
        if mailApps.contains(bundleID) { return true }
        guard PromptMode.browsers.contains(bundleID) else { return false }
        return mailTabs.firstMatch(in: windowTitle, range: NSRange(windowTitle.startIndex..., in: windowTitle)) != nil
    }

    static let instruction = "This is an email. Put the greeting (\"Hi Marcus,\") on its own line followed by a blank line, split the body into short paragraphs, and put a sign-off (\"Thanks,\" / \"Best,\") and the name on their own lines at the end. Don't add a greeting or sign-off the speaker didn't say."

    private static let greeting = try! NSRegularExpression(pattern: #"""
        ^(Hi|Hey|Hello|Dear|Good\s+(?:morning|afternoon|evening))((?:\s+(?:sir|ma'am|madam|team|all|everyone|there|guys|folks|[A-Z][\w'’-]*)){0,2})\s*[,!.:—-]?\s+(?=\S)
        """#, options: [.allowCommentsAndWhitespace])
    private static let signOff = try! NSRegularExpression(pattern: #"""
        (?:^|(?<=[.!?])\s+|\n+)((?:Many\s+)?Thanks(?:\s+(?:so\s+much|a\s+lot|again))?|Thank\s+you(?:\s+so\s+much)?|Best(?:\s+regards)?|Kind\s+regards|Warm\s+regards|Regards|Cheers|Sincerely|Talk\s+soon)
        [,.!]?(?:\s+([A-Z][\w'’-]*(?:\s+[A-Z][\w'’-]*)?))?[.!]?\s*$
        """#, options: [.allowCommentsAndWhitespace])

    static func apply(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return text }
        // Sign-off first, from the end: "…tomorrow. Thanks, Divyanshu." → "…tomorrow.\n\nThanks,\nDivyanshu"
        var closing = ""
        if let m = signOff.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let whole = Range(m.range, in: s),
           let phraseR = Range(m.range(at: 1), in: s), whole.lowerBound > s.startIndex {
            let phrase = String(s[phraseR])
            let name = Range(m.range(at: 2), in: s).map { String(s[$0]) }
            closing = phrase.prefix(1).uppercased() + phrase.dropFirst() + "," + (name.map { "\n" + $0 } ?? "")
            s = String(s[..<whole.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Greeting: "Hi Marcus can you…" → "Hi Marcus,\n\nCan you…"
        var opening = ""
        if let m = greeting.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let whole = Range(m.range, in: s),
           let word = Range(m.range(at: 1), in: s) {
            let who = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? ""
            let rest = String(s[whole.upperBound...])
            if rest.split(separator: " ").count >= 3 {
                opening = String(s[word]) + who + ","
                s = rest.prefix(1).uppercased() + rest.dropFirst()
            }
        }
        guard !opening.isEmpty || !closing.isEmpty else { return text }
        s = paragraphs(s)
        return [opening, s, closing].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Long bodies read better as short paragraphs: break every two or three sentences, never inside a list.
    static func paragraphs(_ body: String) -> String {
        guard !body.contains("\n") else { return body }
        let sentences = body.replacingOccurrences(of: #"(?<=[.!?])\s+(?=[A-Z"“])"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
        guard sentences.count >= 4 else { return body }
        var out: [String] = [], current: [String] = []
        for sentence in sentences {
            current.append(sentence)
            if current.count == 2 || (current.count == 3 && current.joined().count > 220) {
                out.append(current.joined(separator: " ")); current = []
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out.joined(separator: "\n\n")
    }
}

/// Spoken code formatting: "camel case user id" → userId, "snake case user id" → user_id,
/// "package dot json" → package.json, "dot env" → .env, "user underscore id" → user_id.
enum CodeTerms {
    private static let caseCommand = try! NSRegularExpression(pattern: #"""
        \b(camel|snake|kebab|pascal|constant|screaming\s+snake|upper\s+snake|title)[\s-]?case[,:]?\s+
        ((?:[A-Za-z0-9]+(?:\s+|(?=[.,;:!?)])|$)){1,5}?)
        (?=$|[.,;:!?)]|\s*\b(?:and|to|in|for|with|then|please|the|from|on|is|as|inside|into|instead|so)\b)
        """#, options: [.caseInsensitive, .allowCommentsAndWhitespace])
    private static let extensions = "js|ts|tsx|jsx|mjs|py|json|md|swift|yml|yaml|toml|txt|css|scss|html|sh|zsh|go|rs|rb|java|kt|sql|csv|lock|xml|plist|vue|svelte|php|c|cpp|h|m|ipynb|pdf|png|svg"

    static func apply(_ text: String) -> String {
        var s = text
        // "user underscore id" → "user_id"
        while let r = s.range(of: #"\b([A-Za-z0-9]+)\s+underscore\s+([A-Za-z0-9]+)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let parts = s[r].components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty && $0.lowercased() != "underscore" }
            s.replaceSubrange(r, with: parts.joined(separator: "_"))
        }
        // "package dot json" → "package.json", "dot env" → ".env"
        s = s.replacingOccurrences(of: #"\b([A-Za-z0-9_-]+)\s+dot\s+(\#(extensions))\b"#, with: "$1.$2", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"(^|\s)dot\s+(env|gitignore|zshrc|bashrc|npmrc|github|vscode|cursor|claude)\b"#, with: "$1.$2", options: [.regularExpression, .caseInsensitive])
        // "camel case user id" → "userId"
        for m in caseCommand.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let styleR = Range(m.range(at: 1), in: s), let wordsR = Range(m.range(at: 2), in: s) else { continue }
            let words = s[wordsR].split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard !words.isEmpty else { continue }
            let joined = convert(words, style: s[styleR].lowercased())
            let trailing = s[wordsR].hasSuffix(" ") ? " " : ""
            s.replaceSubrange(whole, with: joined + trailing)
        }
        return s
    }

    static func convert(_ words: [String], style: String) -> String {
        let cap = { (w: String) in w.prefix(1).uppercased() + w.dropFirst() }
        switch style.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) {
        case "camel": return words[0] + words.dropFirst().map(cap).joined()
        case "pascal": return words.map(cap).joined()
        case "snake": return words.joined(separator: "_")
        case "kebab": return words.joined(separator: "-")
        case "title": return words.map(cap).joined(separator: " ")
        default: return words.joined(separator: "_").uppercased() // constant / screaming snake / upper snake
        }
    }
}
