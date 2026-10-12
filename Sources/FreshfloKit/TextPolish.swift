import Foundation

/// How swear words are handled in the final text.
enum ProfanityMode: String, CaseIterable, Identifiable {
    case cleanUp, mask, keep

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cleanUp: return "Clean it up"
        case .mask: return "Mask (f***)"
        case .keep: return "Keep as said"
        }
    }
    var detail: String {
        switch self {
        case .cleanUp: return "Removes swear words, or swaps in a polite word so the sentence still reads well."
        case .mask: return "Keeps the word but hides it: f***, s***."
        case .keep: return "Types exactly what you said."
        }
    }
    /// Extra rule for the language model, so it rephrases naturally before the deterministic pass.
    var instruction: String? {
        switch self {
        case .cleanUp: return "Remove swear words and insults. If removing one would break the sentence, use a polite word with the same meaning (\"this is bullshit\" → \"this is nonsense\"). Never add new ideas."
        case .mask, .keep: return "Keep any swear words exactly as spoken."
        }
    }
}

/// The deterministic last pass after every engine (cloud model, Apple's model, the rules, or the fast path).
/// Guarantees the basics even when no language model ran: stutters and repeated phrases, swear words,
/// near-miss spellings of dictionary names, and a few safe grammar fixes.
enum TextPolish {
    struct Options {
        var profanity: ProfanityMode = .cleanUp
        var dictionary: [String] = []
        var grammar = true
        var tone: Tone = .casual
        var translating = false
        /// Format spoken lists ("first… second…", "bullet point…") as one item per line.
        var lists = true
        var bullet = "• "
        /// Mail apps: greeting line, short paragraphs, sign-off block.
        var email = false
    }

    static func apply(_ text: String, _ o: Options) -> String {
        var s = CodeTerms.apply(text)
        s = removeStutters(s)
        s = removeRepeats(s)
        s = filterProfanity(s, mode: o.profanity)
        if !o.translating {
            s = snapToDictionary(s, dictionary: o.dictionary)
            if o.grammar { s = grammarBasics(s, tone: o.tone) }
        }
        s = tidy(s)
        if o.lists { s = ListFormat.apply(s, bullet: o.bullet, capitalize: o.tone != .veryCasual) }
        if o.email { s = EmailFormat.apply(s) }
        return s
    }

    // MARK: Stutters and repeats

    /// "th- the", "w- we", "I- I think" → the word itself.
    static func removeStutters(_ s: String) -> String {
        s.replacingOccurrences(of: #"\b([A-Za-z]{1,4})-\s+(?=\1)"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Words people legitimately say twice in a row.
    private static let keepDoubled: Set<String> = ["had", "that", "very", "bye", "so", "ha", "haha", "knock", "no", "yeah", "really", "far", "again", "more", "many", "go"]

    /// "the the", "I think I think", "we we we" → said once. A repeat right after a full stop ("Go. Go.") is intentional and kept.
    static func removeRepeats(_ s: String) -> String {
        var tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        func key(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        var changed = true
        while changed {
            changed = false
            outer: for n in stride(from: 4, through: 1, by: -1) where tokens.count >= 2 * n {
                var i = 0
                while i + 2 * n <= tokens.count {
                    let first = tokens[i..<i + n].map(key), second = tokens[i + n..<i + 2 * n].map(key)
                    let endsSentence = tokens[i + n - 1].last.map { ".!?".contains($0) } ?? false
                    let allowedDouble = n == 1 && keepDoubled.contains(first[0])
                    // "is is" is a real stutter, but "what it is is" is grammatical; only treat single "is" as a stutter mid-clause.
                    let grammaticalIsIs = n == 1 && first[0] == "is" && i > 0 && ["it", "what", "thing", "problem", "point", "question"].contains(key(tokens[i - 1]))
                    if first == second, !first.contains(""), !endsSentence, !allowedDouble, !grammaticalIsIs {
                        // Keep the first copy, but take the second copy's trailing punctuation ("Friday, Friday." → "Friday.").
                        let lastFirst = tokens[i + n - 1], lastSecond = tokens[i + 2 * n - 1]
                        let trailing = String(lastSecond.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                        let stem = String(lastFirst.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
                        tokens[i + n - 1] = stem + trailing
                        tokens.removeSubrange(i + n..<i + 2 * n)
                        changed = true
                        break outer
                    }
                    i += 1
                }
            }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: Swear words

    /// Phrases first (so the sentence stays readable), then single words. Clean-up replacements keep the meaning.
    private static let cleanPhrases: [(String, String)] = [
        (#"\b(what|where|who|how|why)\s+the\s+(?:fuck|fucking|hell)\b"#, "$1"),
        (#"\bthe\s+fuck\b"#, ""),
        (#"\b(?:fuck|screw)\s+(?:it|this|that)\b[,.]?\s*"#, ""),
        (#"\bfuck(?:ed)?\s+up\b"#, "messed up"),
        (#"\b(?:oh|aw)\s+(?:shit|fuck)\b"#, "oh no"),
        (#"\bholy\s+(?:shit|fuck)\b"#, "wow"),
        (#"\bpiece\s+of\s+shit\b"#, "mess"),
        (#"\bbull\s?shit\b"#, "nonsense"),
        (#"\bmother\s?fuck(?:er|ers|ing)?\b"#, ""),
    ]
    private static let cleanWords: [(String, String)] = [
        (#"\bfuck(?:ing|in'?|ed|s)?\b"#, ""),
        (#"\bgod\s?damn(?:ed|it)?\b"#, ""),
        (#"\bdamn(?:ed|it)?\b"#, ""),
        (#"\bshitty\b"#, "bad"),
        (#"\bshit\b"#, "stuff"),
        (#"\b(?:asshole|arsehole|dickhead|bastard|bitch|cunt|jackass|douchebag)s?\b"#, "jerk"),
        (#"\b(?:chutiy[ae]|chutia|gandu)\b"#, "idiot"),
        (#"\bharami\b"#, "jerk"),
        (#"\b(?:b[eh]+nchod|bhencho|madarchod|bhosdi(?:ke|wale)?|bhosdike|randi|lund|la[uv]?da|lawda|gaand)\b"#, ""),
        (#"\bwtf\b"#, ""),
        (#"\b\w\*{2,}\w*"#, ""), // already masked by the recognizer: f***, s**t
    ]
    private static let maskWords = #"\b(?:mother\s?fuck\w*|fuck\w*|bull\s?shit|shit\w*|god\s?damn\w*|damn\w*|asshole\w*|arsehole\w*|dickhead\w*|bastard\w*|bitch\w*|cunt\w*|chutiy\w*|chutia|gandu|b[eh]+nchod|bhencho|madarchod|bhosdi\w*|wtf)\b"#

    static func filterProfanity(_ s: String, mode: ProfanityMode) -> String {
        switch mode {
        case .keep:
            return s
        case .mask:
            guard let re = try? NSRegularExpression(pattern: maskWords, options: [.caseInsensitive]) else { return s }
            var out = s
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: out) else { continue }
                let word = String(out[r])
                out.replaceSubrange(r, with: String(word.prefix(1)) + String(repeating: "*", count: max(2, word.count - 1)))
            }
            return out
        case .cleanUp:
            var out = s
            for (pattern, replacement) in cleanPhrases + cleanWords {
                out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
            }
            // A removed word at the start of a sentence: capitalize what now starts it.
            out = out.replacingOccurrences(of: #"^\s*[,.]?\s*"#, with: "", options: .regularExpression)
            if s.first?.isUppercase == true, let first = out.first, first.isLowercase {
                out = first.uppercased() + out.dropFirst()
            }
            return out
        }
    }

    // MARK: Dictionary names

    /// Snaps near misses to the user's dictionary: "sharmar" → "Sharma", "Devianchu" → "Divyanshu".
    /// Only when the words sound alike (same Soundex code) and are a few letters apart, so "prior" never becomes "Priya".
    static func snapToDictionary(_ s: String, dictionary: [String]) -> String {
        let terms = dictionary.filter { $0.count >= 4 && $0.allSatisfy { $0.isLetter } }
        guard !terms.isEmpty else { return s }
        let codes = terms.map { ($0, soundex($0), $0.lowercased()) }
        let re = try! NSRegularExpression(pattern: #"\b[A-Za-z]{4,}\b"#)
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            // Never inside an email address, URL or file name.
            let before = r.lowerBound > out.startIndex ? out[out.index(before: r.lowerBound)] : " "
            let after = r.upperBound < out.endIndex ? out[r.upperBound] : " "
            if "@./_-".contains(before) || "@/_".contains(after) || (after == "." && out[r.upperBound...].dropFirst().first?.isLetter == true) { continue }
            let word = String(out[r]), lower = word.lowercased()
            if codes.contains(where: { $0.2 == lower }) {
                // Right word, maybe wrong case: "github" → "GitHub".
                if let exact = codes.first(where: { $0.2 == lower })?.0, exact != word { out.replaceSubrange(r, with: exact) }
                continue
            }
            let code = soundex(word)
            let best = codes
                .filter { $0.1.prefix(3) == code.prefix(3) && $0.2.first == lower.first && abs($0.2.count - lower.count) <= 2 }
                .map { ($0.0, distance(lower, $0.2)) }
                .filter { $0.1 <= max(1, lower.count / 3) }
                .min { $0.1 < $1.1 }
            if let best { out.replaceSubrange(r, with: best.0) }
        }
        return out
    }

    static func soundex(_ word: String) -> String {
        let map: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1", "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = Array(word.lowercased().filter(\.isLetter))
        guard let first = letters.first else { return "" }
        var code = String(first).uppercased()
        var last = map[first]
        for ch in letters.dropFirst() {
            let digit = map[ch]
            if let digit, digit != last { code.append(digit) }
            if ch != "h" && ch != "w" { last = digit }
            if code.count == 4 { break }
        }
        return code.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: Grammar basics

    private static let apostrophes: [(String, String)] = [
        ("dont", "don't"), ("doesnt", "doesn't"), ("didnt", "didn't"), ("cant", "can't"), ("isnt", "isn't"), ("arent", "aren't"),
        ("wasnt", "wasn't"), ("werent", "weren't"), ("havent", "haven't"), ("hasnt", "hasn't"), ("hadnt", "hadn't"),
        ("couldnt", "couldn't"), ("shouldnt", "shouldn't"), ("wouldnt", "wouldn't"), ("theyre", "they're"), ("youre", "you're"),
        ("thats", "that's"), ("whats", "what's"), ("im", "I'm"), ("ive", "I've"), ("youve", "you've"), ("weve", "we've"),
    ]
    /// Vowel letters that sound like consonants, and silent h.
    private static let aNotAn = #"(?:uni|use|usu|uti|ure|euro|eu|one|once|ufo|ubi|uk\b)"#
    private static let anNotA = #"(?:hour|honest|honou?r|heir)"#

    /// Safe, mechanical fixes only (the language model handles real grammar): a/an, "i" → "I", missing apostrophes, sentence capitals.
    static func grammarBasics(_ s: String, tone: Tone) -> String {
        var out = SpokenEnglish.fix(s)
        // a → an before a vowel sound; an → a before a consonant sound. Acronyms and numbers are left alone.
        out = out.replacingOccurrences(of: #"\b([Aa])\s+(?!\#(aNotAn))(?=[aeiouAEIOU][a-z])"#, with: "$1n ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b([Aa])\s+(?=\#(anNotA))"#, with: "$1n ", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\b([Aa])n\s+(?=(?:\#(aNotAn))|[b-df-hj-np-tv-z][a-z])(?!\#(anNotA))"#, with: "$1 ", options: .regularExpression)
        for (wrong, right) in apostrophes {
            out = out.replacingOccurrences(of: #"\b\#(wrong)\b"#, with: right, options: [.regularExpression, .caseInsensitive])
        }
        // Agreement slips that are never correct: "he don't" → "he doesn't", "they was" → "they were", "I is" → "I am".
        out = out.replacingOccurrences(of: #"\b(he|she|it|this|that)\s+don't\b"#, with: "$1 doesn't", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\b(we|they|you)\s+was\b"#, with: "$1 were", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\bI\s+is\b"#, with: "I am", options: .regularExpression)
        // Double negatives: "don't know nothing" → "don't know anything".
        let negation = #"\b((?:do|does|did|can|could|would|should|wo|is|are|was|were|have|has|had)n't|never|cannot)\s+((?:\w+\s+){0,2}?)"#
        for (word, fixed) in [("nothing", "anything"), ("nobody", "anybody"), ("nowhere", "anywhere"), ("no one", "anyone")] {
            out = out.replacingOccurrences(of: negation + word + #"\b"#, with: "$1 $2" + fixed, options: [.regularExpression, .caseInsensitive])
        }
        guard tone != .veryCasual else { return out }
        out = out.replacingOccurrences(of: #"\bi\b(?!\.)"#, with: "I", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\bi'(m|ve|ll|d)\b"#, with: "I'$1", options: [.regularExpression, .caseInsensitive])
        // Capital after a full stop, except after abbreviations like "p.m." or "e.g.".
        let re = try! NSRegularExpression(pattern: #"([.!?])\s+([a-z])"#)
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(m.range, in: out), let letter = Range(m.range(at: 2), in: out) else { continue }
            let before = out[out.startIndex..<whole.lowerBound].suffix(5).lowercased()
            if before.hasSuffix("a.m") || before.hasSuffix("p.m") || before.hasSuffix("e.g") || before.hasSuffix("i.e") || before.hasSuffix("etc") || before.hasSuffix(" vs") { continue }
            out.replaceSubrange(letter, with: out[letter].uppercased())
        }
        return out
    }

    /// Spacing and punctuation left behind by removals.
    static func tidy(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #",\s*([,.!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^[\s,;:]+"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
