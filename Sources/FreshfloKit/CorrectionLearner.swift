import AppKit
import ApplicationServices

/// Watches what happens to inserted text and learns words the user corrects by hand,
/// e.g. "devanshu" → "Divyanshu" or "github" → "GitHub", adding them to the dictionary.
final class CorrectionLearner {
    private struct Pending {
        let element: AXUIElement
        let anchor: String
        let inserted: String
    }

    var onLearn: ((String) -> Void)?
    private var pending: Pending?
    private var checkWork: DispatchWorkItem?

    /// Remember an insertion so it can be compared against the field later.
    func track(inserted: String, context: FocusContext) {
        check()
        guard let element = context.element, let before = context.textBefore else { return }
        pending = Pending(element: element, anchor: String(before.suffix(40)), inserted: inserted.trimmingCharacters(in: .whitespacesAndNewlines))
        let work = DispatchWorkItem { [weak self] in self?.check() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Compare now (called on a timer, and before the next dictation starts).
    func check() {
        checkWork?.cancel()
        checkWork = nil
        guard let p = pending else { return }
        pending = nil
        guard let current = FocusContext.currentText(of: p.element) else { return }
        for word in Self.learnedWords(inserted: p.inserted, anchor: p.anchor, current: current) {
            onLearn?(word)
        }
    }

    /// Finds single-word substitutions between what was inserted and what's in the field now.
    static func learnedWords(inserted: String, anchor: String, current: String) -> [String] {
        let ns = current as NSString
        var searchStart = 0
        if !anchor.isEmpty {
            let r = ns.range(of: anchor, options: .backwards)
            guard r.location != NSNotFound else { return [] }
            searchStart = r.location + r.length
        }
        let length = min(ns.length - searchStart, (inserted as NSString).length + 80)
        guard length > 0 else { return [] }
        let region = ns.substring(with: NSRange(location: searchStart, length: length))

        let old = tokens(inserted)
        let new = Array(tokens(region).prefix(old.count + 10))
        guard !old.isEmpty, !new.isEmpty else { return [] }

        // LCS alignment on lowercase tokens; case-only differences are compared separately.
        let n = old.count, m = new.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = old[i].lowercased() == new[j].lowercased() ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // The region after the insertion may contain unrelated text; require most of it to still match.
        let required = n <= 3 ? n - 1 : Int((Double(n) * 0.6).rounded(.up))
        guard dp[0][0] >= max(1, required) else { return [] }

        var learned: [String] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i].lowercased() == new[j].lowercased() {
                if old[i] != new[j], isCaseFix(old[i], new[j], atStart: i == 0) { learned.append(new[j]) }
                i += 1; j += 1
            } else if i + 1 == n || (j + 1 < m && old[i + 1].lowercased() == new[j + 1].lowercased()) {
                // One word replaced by one word (or the final word replaced).
                if isPlausibleFix(old[i], new[j]) { learned.append(new[j]) }
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return Array(Set(learned))
    }

    private static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-.")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-.")) }
            .filter { !$0.isEmpty }
    }

    /// A correction worth learning: similar spelling (a mishearing, not a rewrite) of a non-trivial word.
    private static func isPlausibleFix(_ old: String, _ new: String) -> Bool {
        guard new.count >= 3, old.lowercased() != new.lowercased(), !new.allSatisfy(\.isNumber) else { return false }
        let distance = levenshtein(old.lowercased(), new.lowercased())
        return distance <= max(1, new.count / 3) && isDistinctive(new)
    }

    /// "github" → "GitHub", "divyanshu" → "Divyanshu" (but not sentence-start capitalization of everyday words).
    private static func isCaseFix(_ old: String, _ new: String, atStart: Bool) -> Bool {
        guard new.count >= 2 else { return false }
        if new.dropFirst().contains(where: \.isUppercase) { return true }
        return !atStart && old == old.lowercased() && new.first?.isUppercase == true && !commonWords.contains(new.lowercased())
    }

    /// Names, brands and jargon rather than everyday words the transcriber already knows.
    private static func isDistinctive(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return true } // GitHub, iOS, McDonald
        if word.first?.isUppercase == true { return true }
        return !commonWords.contains(word.lowercased())
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did",
        "its", "let", "put", "say", "she", "too", "use", "that", "with", "have", "this", "will", "your", "from", "they",
        "know", "want", "been", "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long",
        "make", "many", "more", "only", "over", "such", "take", "than", "them", "well", "were", "what", "then", "there",
        "their", "would", "could", "should", "about", "which", "these", "other", "think", "where", "after", "again",
        "also", "back", "into", "need", "next", "send", "sent", "meet", "call", "today", "tomorrow", "week", "please",
        "thanks", "thank", "sure", "okay", "yes", "yeah", "maybe", "really", "going", "doing", "done", "still",
    ]
}
