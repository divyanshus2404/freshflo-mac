import Foundation

/// Deterministic regional formatting applied after cleanup, so it doesn't depend on the model following instructions.
enum Regional {
    static func apply(_ text: String, _ format: RegionalFormat) -> String {
        var t = spokenEmails(text)
        guard format == .india else { return t }
        let number = #"(\d[\d,]*(?:\.\d+)?)"#
        // "5 lakh rupees" → "₹5 lakh", "1500 rupees" → "₹1,500", "Rs. 200" / "INR 200" → "₹200"
        t = replace(t, #"\b"# + number + #"\s+(lakhs?|crores?)\s+(?:rupees?|rs\.?)\b"#, "₹$1 $2")
        t = replace(t, #"\b"# + number + #"\s+(?:rupees?|rs\.?)(?![\p{L}])"#, "₹$1")
        t = replace(t, #"\b(?:rs\.?|inr)\s?(?=\d)"#, "₹")
        return groupIndian(t)
    }

    /// "rahul at the rate gmail dot com" / "rahul at gmail dot com" → rahul@gmail.com
    static func spokenEmails(_ s: String) -> String {
        let tld = #"(com|in|org|net|co|io|ai|edu|gov|dev|app|co\.in|co\.uk)"#
        return replace(s, #"\b([a-z0-9][a-z0-9._+-]*)\s+(?:at the rate(?: of)?|at)\s+([a-z0-9-]+)\s*(?:dot|\.)\s*"# + tld + #"\b"#, "$1@$2.$3")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// ₹150000 → ₹1,50,000 (Indian digit grouping) for amounts written without separators.
    private static func groupIndian(_ s: String) -> String {
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
}
