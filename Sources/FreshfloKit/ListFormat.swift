import Foundation

/// Spoken lists become written lists; everything else stays as sentences.
/// "first eggs second milk third bread" → a numbered list, "bullet point eggs next point milk" → bullets,
/// "I need three things: eggs, milk and bread" → bullets. Runs after every engine, so a list comes out the same way
/// whether the language model, Apple's model or the rules cleaned the text up. Also powers the live captions' "List · 3".
enum ListFormat {
    enum Kind: Equatable { case numbered, bulleted }

    struct Detection: Equatable {
        var kind: Kind?
        var items = 0
        static let sentences = Detection(kind: nil, items: 0)
    }

    /// "- " for apps that render Markdown (AI tools, editors, notes apps), "• " everywhere else.
    static func bullet(for bundleID: String, windowTitle: String = "") -> String {
        if PromptMode.isAITarget(bundleID: bundleID, windowTitle: windowTitle) || PromptMode.aiApps.contains(bundleID) { return "- " }
        return markdownApps.contains(bundleID) || PromptMode.terminals.contains(bundleID) ? "- " : "• "
    }
    private static let markdownApps: Set<String> = [
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.sublimetext.4", "dev.zed.Zed", "com.jetbrains.intellij", "com.github.GitHubClient",
        "md.obsidian", "notion.id", "com.linear", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "abnerworks.Typora",
        "com.bear-writer.BearNotes", "net.shinyfrog.bear", "com.craft.craft", "com.logseq.logseq",
    ]

    // MARK: Detection

    static func detect(_ text: String) -> Detection {
        if let lines = existingList(text) { return Detection(kind: lines.kind, items: lines.items.count) }
        if let parsed = parseMarkers(text) { return Detection(kind: parsed.kind, items: parsed.items.count) }
        if let counted = parseCounted(text) { return Detection(kind: counted.kind, items: counted.items.count) }
        return .sentences
    }

    // MARK: Formatting

    /// Rewrites a spoken list as one item per line. Returns the text unchanged when it isn't a list.
    static func apply(_ text: String, bullet: String = "• ", capitalize: Bool = true) -> String {
        let found = existingList(text) ?? parseMarkers(text) ?? parseCounted(text)
        guard var parsed = found, parsed.items.count >= 2 || (parsed.kind == .bulleted && parsed.explicit && parsed.items.count >= 1) else { return text }
        var lines: [String] = []
        let intro = cleanIntro(parsed.intro, capitalize: capitalize)
        if !intro.isEmpty { lines.append(intro) }
        var outro = parsed.outro.trimmingCharacters(in: .whitespacesAndNewlines)
        var number = 0
        // "1. First book the ticket, 2. Second confirm the hotel": when every item opens with the next order word,
        // the numbers already say it, so the words go. ("1. First class tickets, 2. Hotel" keeps "First".)
        if parsed.kind == .numbered, orderedOpeners(parsed.items) {
            parsed.items = parsed.items.map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"(?i)^(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?|sixth|seventh|eighth|ninth|tenth|next|then|after that|finally|lastly)\b(?:\s+of\s+all)?[,:]?\s+(?=\w)"#, with: "", options: .regularExpression)
            }
        }
        for (i, raw) in parsed.items.enumerated() {
            var item = raw
            if i == parsed.items.count - 1, outro.isEmpty {
                let split = splitOutro(item)
                item = split.item
                outro = split.outro
            }
            item = cleanItem(item, capitalize: capitalize)
            guard !item.isEmpty else { continue }
            number += 1
            lines.append((parsed.kind == .numbered ? "\(number). " : bullet) + item)
        }
        var out = lines.joined(separator: "\n")
        if !outro.isEmpty { out += "\n\n" + (capitalize ? capitalized(outro) : outro) }
        return out
    }

    // MARK: Parsing

    private struct Parsed {
        var kind: Kind
        var intro: String
        var items: [String]
        var outro = ""
        /// Said "bullet point" out loud: one item is enough.
        var explicit = false
    }

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// Matches every list marker; which kind it is gets decided afterwards.
    private static let markerRegex = try! NSRegularExpression(pattern: #"""
        (?ix)
        (?<![\w'-])(?:
            (?<ord>first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?(?:\s+of\s+all)?
          | (?:number|step|point|item|option|no\.)\s+(?<num>one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})
          | (?<last>lastly|finally|and\s+finally|last\s+but\s+not\s+least)
          | (?<bul>(?:(?:next|new|another|and)\s+)?bullet(?:\s+point)?|next\s+(?:point|item))
          | (?<digit>\d{1,2})[.)](?=\s)
        )(?![\w'])
        """#)

    private struct Marker {
        var range: Range<String.Index>
        var index: Int?      // 1-based position for ordinal and numbered markers
        var isLast = false
        var isBullet = false
    }

    private static func markers(in text: String) -> [Marker] {
        let ns = NSRange(text.startIndex..., in: text)
        // Raw speech (live captions, the offline fallback) has no punctuation to mark clauses, so later markers can't need one.
        let unpunctuated = text.rangeOfCharacter(from: CharacterSet(charactersIn: ".;:!?\n")) == nil  // live recognizers sprinkle commas
        var found: [Marker] = []
        for m in markerRegex.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text) else { continue }
            func group(_ name: String) -> String? {
                let g = m.range(withName: name)
                return g.location == NSNotFound ? nil : Range(g, in: text).map { String(text[$0]).lowercased() }
            }
            var marker: Marker
            if let o = group("ord"), let i = ordinals.firstIndex(of: o) { marker = Marker(range: r, index: i + 1) }
            else if let n = group("num") ?? group("digit") { marker = Marker(range: r, index: cardinals.firstIndex(of: n).map { $0 + 1 } ?? Int(n)) }
            else if group("last") != nil { marker = Marker(range: r, isLast: true) }
            else if group("bul") != nil { marker = Marker(range: r, isBullet: true) }
            else { continue }
            // Saying "bullet point" is unambiguous. Other markers count only at the start of a clause:
            // "second, milk" does, "wait a second" doesn't. A list still has to start at a clause.
            guard marker.isBullet || unpunctuated || atClauseStart(text, r.lowerBound) else { continue }
            found.append(marker)
        }
        return found
    }

    private static func atClauseStart(_ text: String, _ i: String.Index) -> Bool {
        let before = text[text.startIndex..<i].trimmingCharacters(in: .whitespaces)
        if before.isEmpty { return true }
        if let last = before.last, ".,;:!?\n—–-".contains(last) { return true }
        let lower = before.lowercased()
        for joiner in [" and", " then", " and then", " also", " plus", " um", " uh", " so", " okay"] where lower.hasSuffix(joiner) || lower == joiner.trimmingCharacters(in: .whitespaces) {
            return true
        }
        return false
    }

    private static func parseMarkers(_ text: String) -> Parsed? {
        let all = markers(in: text)
        guard !all.isEmpty else { return nil }

        // Numbered: a run that starts at 1 and counts up (first, second, third… / step one, step two… / 1. 2. 3.), optionally ending with "finally".
        var run: [Marker] = []
        for m in all {
            if let i = m.index {
                if i == run.count + 1 { run.append(m) } else if i == 1 { run = [m] }
            } else if m.isLast, run.count >= 2 {
                run.append(m)
                break
            }
        }
        if run.count >= 2 {
            var parsed = split(text, at: run, kind: .numbered)
            // Still talking ("…second my passport and third"): the last marker has nothing after it yet.
            if parsed.items.count > 2, isBlank(parsed.items.last!) { parsed.items.removeLast() }
            // Every item needs words: "I came first in the race and my friend came second" isn't a list.
            if parsed.items.count >= 2, !parsed.items.contains(where: isBlank) { return parsed }
        }
        // Bulleted: said "bullet point" / "next point".
        let bullets = all.filter(\.isBullet)
        if !bullets.isEmpty {
            var parsed = split(text, at: bullets, kind: .bulleted)
            parsed.explicit = true
            return parsed
        }
        return nil
    }

    private static func isBlank(_ item: String) -> Bool {
        cleanItem(item, capitalize: false).isEmpty
    }

    private static func split(_ text: String, at marks: [Marker], kind: Kind) -> Parsed {
        let intro = String(text[text.startIndex..<marks[0].range.lowerBound])
        var items: [String] = []
        for (i, m) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].range.lowerBound : text.endIndex
            items.append(String(text[m.range.upperBound..<end]))
        }
        return Parsed(kind: kind, intro: intro, items: items)
    }

    /// "I need three things: eggs, milk and bread" — the spoken count has to match the items, so ordinary commas don't turn into lists.
    private static let countedRegex = try! NSRegularExpression(pattern: #"""
        (?ix)
        ^(?<intro>.*?\b(?<n>two|three|four|five|six|seven|[2-7])\s+(?:\w+\s+)?(?<what>things?|items?|points?|steps?|reasons?|options?|ideas?|tasks?|questions?|priorities|goals?|changes?|updates?)\b[^.?!:]{0,40}?)[:,]\s*
        (?<rest>[^.?!]+?)(?<end>[.?!].*)?$
        """#)

    private static func parseCounted(_ text: String) -> Parsed? {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = countedRegex.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)),
              let introR = Range(m.range(withName: "intro"), in: flat), let nR = Range(m.range(withName: "n"), in: flat),
              let restR = Range(m.range(withName: "rest"), in: flat) else { return nil }
        let nWord = flat[nR].lowercased()
        guard let n = cardinals.firstIndex(of: nWord).map({ $0 + 1 }) ?? Int(nWord) else { return nil }
        let rest = String(flat[restR])
        let items = rest
            .replacingOccurrences(of: #",?\s+(?:and|or|plus)\s+(?=[^,]+$)"#, with: ", ", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard items.count == n, items.allSatisfy({ $0.split(separator: " ").count <= 8 }) else { return nil }
        var parsed = Parsed(kind: flat[introR].lowercased().contains("step") ? .numbered : .bulleted, intro: String(flat[introR]) + ":", items: items)
        if let endR = Range(m.range(withName: "end"), in: flat) {
            let end = String(flat[endR]).trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
            if !end.isEmpty { parsed.outro = end + "." }
        }
        return parsed
    }

    /// Text that is already a list (from the language model): normalise the markers so every list looks the same.
    private static let lineMarker = try! NSRegularExpression(pattern: #"^\s*(?:(\d{1,2})[.)]|[-•*–])\s+"#)

    private static func existingList(_ text: String) -> Parsed? {
        let lines = text.components(separatedBy: "\n")
        var intro: [String] = [], items: [String] = [], after: [String] = []
        var numbered = true
        for line in lines {
            let ns = NSRange(line.startIndex..., in: line)
            if let m = lineMarker.firstMatch(in: line, range: ns), let r = Range(m.range, in: line), after.isEmpty {
                if m.range(at: 1).location == NSNotFound { numbered = false }
                items.append(String(line[r.upperBound...]))
            } else if items.isEmpty {
                intro.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty || !after.isEmpty {
                after.append(line)
            }
        }
        guard items.count >= 2 else { return nil }
        var parsed = Parsed(kind: numbered ? .numbered : .bulleted, intro: intro.joined(separator: "\n"), items: items)
        let tail = after.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.outro = tail
        return parsed
    }

    private static func orderedOpeners(_ items: [String]) -> Bool {
        guard items.count >= 2 else { return false }
        for (i, item) in items.enumerated() {
            let w = item.trimmingCharacters(in: .whitespaces).lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            let expected = i < ordinals.count ? ordinals[i] : ""
            let ok = w == expected || w == expected + "ly" || (i > 0 && ["next", "then", "finally", "lastly"].contains(w))
            if !ok { return false }
        }
        return true
    }

    // MARK: Cleaning pieces

    private static func cleanIntro(_ s: String, capitalize: Bool) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lead-in made only of filler ("um so", "okay") isn't worth a line.
        t = t.replacingOccurrences(of: #"(?i)^(?:(?:um+|uh+|so|okay|ok|well|like|basically|and|right)\b[,.]?\s*)+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)(?:[,;]?\s*\b(?:and|so|um+|uh+|okay|like)\b)+\s*[,;]?\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;—–-"))
        guard !t.isEmpty else { return "" }
        let fix = { (x: String) in capitalize ? capitalized(x) : x }
        if t.hasSuffix("?") || t.hasSuffix("!") || t.hasSuffix(":") { return fix(t) }
        if t.hasSuffix(".") { t.removeLast() }
        return fix(t) + ":"
    }

    private static func cleanItem(_ s: String, capitalize: Bool) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Connectors left over from the marker: "first of all, …", "second is …", "step one: …".
        t = t.replacingOccurrences(of: #"(?i)^(?:[,:;.\-–—)]\s*)*(?:(?:thing|point|step|item|one)\s+(?:is|was|would be)\b\s*)?(?:is\b\s*)?[,:\-–—]?\s*"#,
                                   with: "", options: .regularExpression)
        // Joiners that belong to the next marker: "eggs, and" → "eggs".
        t = t.replacingOccurrences(of: #"(?i)[,;]?\s*\b(?:and|then|and then|also|plus|um|uh|so|okay)\s*[,;]?$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;—–-\n"))
        // Short fragments read better without a full stop; real sentences keep theirs.
        let inner = t.dropLast().contains { ".!?".contains($0) }
        if t.hasSuffix("."), !inner, t.split(separator: " ").count <= 12 { t.removeLast() }
        return capitalize ? capitalized(t) : t
    }

    /// The last item often carries a closing sentence: "third, sunscreen. That should be everything."
    private static func splitOutro(_ s: String) -> (item: String, outro: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"[.!?]\s+(?=[A-Z])"#, options: .regularExpression) else { return (t, "") }
        let item = String(t[..<r.lowerBound]), outro = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard item.split(separator: " ").count <= 12, outro.split(separator: " ").count >= 2 else { return (t, "") }
        return (item, outro)
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
