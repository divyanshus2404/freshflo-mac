import AppKit
import Foundation

enum SnippetExpander {
    /// Lowercased, punctuation-free, single-spaced form used for matching spoken triggers.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The expansion when the whole utterance is just a trigger phrase.
    static func wholeMatch(_ transcript: String, snippets: [Snippet]) -> String? {
        let spoken = normalize(transcript)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { !normalize($0.trigger).isEmpty && normalize($0.trigger) == spoken }.map { fill($0.expansion) }
    }

    static let variables = ["{date}", "{time}", "{day}", "{tomorrow}", "{clipboard}"]

    /// Fills template variables: {date}, {time}, {day}, {tomorrow}, {clipboard}.
    static func fill(_ expansion: String, now: Date = Date(), clipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }) -> String {
        guard expansion.contains("{") else { return expansion }
        var s = expansion
        s = s.replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
        s = s.replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
        s = s.replacingOccurrences(of: "{day}", with: now.formatted(.dateTime.weekday(.wide)))
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            s = s.replacingOccurrences(of: "{tomorrow}", with: tomorrow.formatted(date: .long, time: .omitted))
        }
        if s.contains("{clipboard}") { s = s.replacingOccurrences(of: "{clipboard}", with: clipboard() ?? "") }
        return s
    }

    /// Replaces trigger phrases that appear inside a longer dictation.
    static func applyInline(_ text: String, snippets: [Snippet]) -> String {
        var result = text
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = normalize(snippet.trigger).split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s,.;:!?-]*"#) + #"(?![\p{L}\p{N}])[.!?]?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: fill(snippet.expansion))
            )
        }
        return result
    }
}
