import Foundation

/// Deterministic regional formatting applied after cleanup, so it doesn't depend on the model following instructions.
enum Regional {
    static func apply(_ text: String, _ format: RegionalFormat) -> String {
        var t = lowercaseEmails(digitsForAmounts(spokenEmails(text)))
        guard format == .india else { return t }
        t = rupeesInWords(t)
        let number = #"(\d[\d,]*(?:\.\d+)?)"#
        // "5 lakh rupees" → "₹5 lakh", "1500 rupees" → "₹1,500", "Rs. 200" / "INR 200" → "₹200"
        t = replace(t, #"\b"# + number + #"\s+(lakhs?|crores?)\s+(?:rupees?|rs\.?)\b"#, "₹$1 $2")
        t = replace(t, #"\b"# + number + #"\s+(?:rupees?|rs\.?)(?![\p{L}])"#, "₹$1")
        t = replace(t, #"\b(?:rs\.?|inr)\s?(?=\d)"#, "₹")
        return groupIndian(t)
    }

    private static let smallNumber = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[-‑– ](?:one|two|three|four|five|six|seven|eight|nine))?"#
    /// Things people count in dictation. A number word in front of one of these becomes digits.
    /// Time and percentages: always digits ("5 minutes", "45%").
    private static let measures = #"(minutes?|hours?|days?|weeks?|months?|years?|seconds?|percent|per cent)"#
    /// Things people count: digits from 10 up ("50 users"); one to nine stay words ("two meetings"), as in most style guides.
    private static let countable = #"(people|persons|members|times|users|customers|clients|employees|items|pages|files|tickets|orders|slides|tasks|emails|calls|meetings)"#

    /// Durations, counts, percentages and clock times as digits, the way Freshflo writes English ("fifteen minutes"
    /// → "15 minutes", "forty five percent" → "45%", "at ten o'clock" → "at 10", "ten to fifteen minutes" →
    /// "10 to 15 minutes"). Narrow on purpose: "one day I'll…" and "at one point" stay words.
    static func digitsForAmounts(_ text: String) -> String {
        func digits(_ phrase: String) -> String? {
            Regional.number(fromWords: phrase.lowercased().split(whereSeparator: { " -‑–".contains($0) }).map(String.init)).map(String.init)
        }
        func replace(_ pattern: String, in t: inout String, _ build: (NSTextCheckingResult, String) -> String?) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t), let new = build(m, t) else { continue }
                t.replaceSubrange(whole, with: new)
            }
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, _ t: String) -> String? {
            Range(m.range(at: i), in: t).map { String(t[$0]) }
        }
        var t = text
        let start = #"(?<![\w\-‑–])"#
        // "ten to fifteen minutes", "two or three days"
        replace(start + "(" + smallNumber + #")\s+(to|or)\s+("# + smallNumber + #")\s+"# + measures + #"\b"#, in: &t) { m, t in
            guard let a = group(m, 1, t).flatMap(digits), let b = group(m, 3, t).flatMap(digits), let joiner = group(m, 2, t), let unit = group(m, 4, t) else { return nil }
            return "\(a) \(joiner) \(b) \(unit)"
        }
        // "fifteen minutes", "forty five percent"; not a lone "one" ("one day", "one minute").
        replace(start + #"(?!one\b)("# + smallNumber + #")\s+"# + measures + #"\b"#, in: &t) { m, t in
            guard let n = group(m, 1, t).flatMap(digits), let unit = group(m, 2, t) else { return nil }
            return unit.lowercased().hasPrefix("per") ? "\(n)%" : "\(n) \(unit)"
        }
        // "fifty users", "twelve tickets"; "two meetings" stays words.
        replace(start + "(" + smallNumber + #")\s+"# + countable + #"\b"#, in: &t) { m, t in
            guard let n = group(m, 1, t).flatMap(digits).flatMap(Int.init), n >= 10, let unit = group(m, 2, t) else { return nil }
            return "\(n) \(unit)"
        }
        // Digits already: "12 percent" → "12%".
        replace(#"\b(\d+(?:\.\d+)?)\s+(?:percent|per cent)\b"#, in: &t) { m, t in group(m, 1, t).map { "\($0)%" } }
        // "at ten o'clock" is always a time; a bare "at ten" only when what follows says so.
        let after = #"(?=\s*(?:[.,;!?]|$|a\.?m\b|p\.?m\b|in the (?:morning|afternoon|evening|night)|tonight|tomorrow|today|sharp))"#
        replace(#"\bat ("# + smallNumber + #")(?: o['’]clock\b|"# + after + ")", in: &t) { m, t in
            guard let n = group(m, 1, t).flatMap(digits) else { return nil }
            return (t[Range(m.range, in: t)!].hasPrefix("A") ? "At " : "at ") + n
        }
        return t
    }

    /// "rahul at the rate gmail dot com" / "rahul at gmail dot com" → rahul@gmail.com
    /// Email addresses are written in lower case: a model starting a sentence with one shouldn't give "Rahul@gmail.com".
    static func lowercaseEmails(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            if let r = Range(m.range, in: out) { out.replaceSubrange(r, with: out[r].lowercased()) }
        }
        return out
    }

    static func spokenEmails(_ s: String) -> String {
        let tld = #"(com|in|org|net|co|io|ai|edu|gov|dev|app|co\.in|co\.uk)"#
        return replace(s, #"\b([a-z0-9][a-z0-9._+-]*)\s+(?:at the rate(?: of)?|at)\s+([a-z0-9-]+)\s*(?:dot|\.)\s*"# + tld + #"\b"#, "$1@$2.$3")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// ₹150000 or ₹150,000 → ₹1,50,000 (Indian digit grouping), whatever grouping the model used.
    private static func groupIndian(_ input: String) -> String {
        // Strip existing separators inside ₹ amounts first so Western "250,000" is regrouped too.
        var s = input
        if let western = try? NSRegularExpression(pattern: #"₹(\d{1,3}(?:,\d{2,3})+)(?!\d)"#) {
            for match in western.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(match.range(at: 1), in: s) else { continue }
                s.replaceSubrange(r, with: s[r].replacingOccurrences(of: ",", with: ""))
            }
        }
        guard let re = try? NSRegularExpression(pattern: #"₹(\d{4,})(?![\d,])"#) else { return s }
        var result = s
        for match in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(match.range(at: 1), in: s) else { continue }
            let digits = Array(s[r])
            var groups: [String] = [String(digits.suffix(3))]
            var rest = digits.dropLast(3)
            while !rest.isEmpty {
                groups.insert(String(rest.suffix(2)), at: 0)
                rest = rest.dropLast(2)
            }
            if let full = Range(match.range(at: 1), in: result) {
                result.replaceSubrange(full, with: groups.joined(separator: ","))
            }
        }
        return result
    }

    // MARK: Amounts said in words

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "a": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "lakh": 100_000, "lakhs": 100_000, "crore": 10_000_000, "crores": 10_000_000, "million": 1_000_000]

    /// Reads "two lakh fifty thousand", "five thousand", "one hundred and twenty". Nil if it isn't a number.
    static func number(fromWords words: [String]) -> Int? {
        var total = 0, current = 0, any = false
        for raw in words {
            let w = raw.lowercased().replacingOccurrences(of: "-", with: " ")
            for part in w.split(separator: " ").map(String.init) {
                if part == "and" { continue }
                if let u = units[part] { current += u; any = true }
                else if let sc = scales[part] {
                    if sc == 100 { current = max(current, 1) * 100 }
                    else { total += max(current, 1) * sc; current = 0 }
                    any = true
                } else if let d = Int(part.replacingOccurrences(of: ",", with: "")) { current += d; any = true }
                else { return nil }
            }
        }
        return any ? total + current : nil
    }

    /// "five thousand rupees" / "two lakh fifty thousand rupees" → "₹5,000" / "₹2,50,000".
    static func rupeesInWords(_ s: String) -> String {
        let word = #"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|lakhs?|crores?|million|and|a|\d[\d,]*)"#
        guard let re = try? NSRegularExpression(pattern: #"\b((?:"# + word + #"[\s-]+)*"# + word + #")\s+(?:rupees?|rupaye|rs\.?)(?![\p{L}])"#, options: [.caseInsensitive]) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let numR = Range(m.range(at: 1), in: out) else { continue }
            let words = out[numR].split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            // Amounts that already have digits ("5 lakh rupees" → "₹5 lakh") are handled by the rule above.
            if words.contains(where: { $0.first?.isNumber == true }) { continue }
            // Don't turn "a rupee" or a bare "and" into a number.
            guard words.contains(where: { units[$0.lowercased()] != nil && $0.lowercased() != "a" || scales[$0.lowercased()] != nil || Int($0.replacingOccurrences(of: ",", with: "")) != nil }),
                  let n = number(fromWords: words), n > 0 else { continue }
            // A round "five crore" / "two lakh" reads better as ₹5 crore / ₹2 lakh than as ₹5,00,00,000.
            let lower = words.map { $0.lowercased() }
            if let last = lower.last, ["crore", "crores", "lakh", "lakhs"].contains(last), lower.count >= 2,
               !lower.dropLast().contains(where: { scales[$0] != nil }), let small = number(fromWords: Array(words.dropLast())) {
                out.replaceSubrange(whole, with: "₹\(small) \(last.hasPrefix("crore") ? "crore" : "lakh")")
                continue
            }
            out.replaceSubrange(whole, with: "₹" + indianGrouping(n))
        }
        return out
    }

    static func indianGrouping(_ n: Int) -> String {
        let digits = Array(String(n))
        guard digits.count > 3 else { return String(digits) }
        var groups = [String(digits.suffix(3))]
        var rest = digits.dropLast(3)
        while !rest.isEmpty { groups.insert(String(rest.suffix(2)), at: 0); rest = rest.dropLast(2) }
        return groups.joined(separator: ",")
    }
}
