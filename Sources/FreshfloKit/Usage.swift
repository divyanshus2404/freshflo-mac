import Foundation

/// Daily totals that outlive the 500-entry History: the menu's "today" line, streaks and the weekly recap.
/// Stored as ["yyyy-MM-dd": [words, secondsSpoken]] in UserDefaults; nothing leaves the Mac.
final class UsageStats {
    static let shared = UsageStats()
    /// Average typing speed used for "time saved".
    static let typingWPM = 40.0

    private let defaults = UserDefaults.standard
    private let key = "usage.days"
    private var days: [String: [Double]]
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        days = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        if days.isEmpty, !HistoryStore.shared.items.isEmpty {
            for item in HistoryStore.shared.items { add(words: item.wordCount, seconds: item.duration, on: item.date) }
            save()
        }
    }

    func words(on date: Date) -> Int { Int(days[formatter.string(from: date)]?[0] ?? 0) }

    func record(words: Int, seconds: Double, on date: Date = Date()) {
        add(words: words, seconds: seconds, on: date)
        save()
    }

    struct Totals {
        var words = 0
        var seconds = 0.0
        /// Minutes it would have taken to type, minus the time spent speaking.
        var minutesSaved: Int { max(0, Int((Double(words) / UsageStats.typingWPM - seconds / 60).rounded())) }
    }

    var today: Totals { totals(lastDays: 1) }
    var thisWeek: Totals { totals(lastDays: 7) }
    var allTime: Totals {
        days.values.reduce(into: Totals()) { $0.words += Int($1[0]); $0.seconds += $1[1] }
    }

    /// Consecutive days with at least one dictation, counting today or ending yesterday.
    var streak: Int {
        let calendar = Calendar.current
        var day = Date()
        if (days[formatter.string(from: day)]?[0] ?? 0) == 0 { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while (days[formatter.string(from: day)]?[0] ?? 0) > 0 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    private func totals(lastDays: Int) -> Totals {
        var out = Totals()
        for offset in 0..<lastDays {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()),
                  let value = days[formatter.string(from: date)] else { continue }
            out.words += Int(value[0])
            out.seconds += value[1]
        }
        return out
    }

    private func add(words: Int, seconds: Double, on date: Date) {
        let k = formatter.string(from: date)
        var value = days[k] ?? [0, 0]
        value[0] += Double(words)
        value[1] += seconds
        days[k] = value
    }

    private func save() {
        // Keep about a year so the file stays tiny.
        if days.count > 400, let cutoff = Calendar.current.date(byAdding: .day, value: -370, to: Date()) {
            let c = formatter.string(from: cutoff)
            days = days.filter { $0.key >= c }
        }
        defaults.set(days, forKey: key)
    }
}

/// One tip a day in the menu, so people discover the features that make them come back.
enum Tips {
    static let all: [String] = [
        "Say “scratch that” right after a dictation to delete it.",
        "Hold %@ + Control and say “make that shorter” to edit your last dictation.",
        "Hold %@ + Shift and ask “what does this mean?” about selected text.",
        "Tap %@ once for hands-free. Tap again when you're done.",
        "Say “new line” or “new paragraph” to break up long dictations.",
        "Fix a misheard name once and Freshflo learns it.",
        "Set a tone per app in Settings → Style: formal in Mail, casual in Slack.",
        "Speak Hindi or Hinglish and get English: Settings → Style → Write in.",
        "Save text you type often in Settings → Snippets, then just say its name.",
        "Start Meeting Notes from this menu for You / Them notes with action items.",
        "Drop a WhatsApp voice note into “Transcribe Audio File…” for clean text.",
        "Press Esc while talking to cancel without typing anything.",
        "Hold %@ + Shift and say “remind me to call Rahul at 5” to add a reminder.",
        "History lets you re-polish any past dictation as formal, shorter or bullets.",
    ]

    static func today(key: String) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return String(format: all[day % all.count], key)
    }
}
