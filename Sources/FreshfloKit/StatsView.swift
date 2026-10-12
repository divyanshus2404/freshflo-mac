import Charts
import SwiftUI

/// "Your Freshflo": the week at a glance. Words, time saved, speaking speed, streak, where you dictate most,
/// and how much cleanup Freshflo did for you. Computed on this Mac from History and the daily totals.
struct StatsSummary {
    struct Day: Identifiable {
        let date: Date
        let words: Int
        var id: Date { date }
    }
    struct App: Identifiable {
        let name: String
        let dictations: Int
        let words: Int
        var id: String { name }
    }

    var weekWords = 0
    var weekMinutesSaved = 0
    var weekDictations = 0
    var allTimeWords = 0
    var allTimeMinutesSaved = 0
    var speakingWPM = 0
    var streak = 0
    var days: [Day] = []
    var apps: [App] = []
    var wordsCleaned = 0
    var lists = 0
    var onDevicePercent = 0
    var medianLatencyMs = 0

    static func current(history: [HistoryItem] = HistoryStore.shared.items, usage: UsageStats = .shared, now: Date = Date()) -> StatsSummary {
        var s = StatsSummary()
        let week = usage.thisWeek, all = usage.allTime
        s.weekWords = week.words
        s.weekMinutesSaved = week.minutesSaved
        s.allTimeWords = all.words
        s.allTimeMinutesSaved = all.minutesSaved
        s.speakingWPM = week.seconds > 30 ? Int(Double(week.words) / (week.seconds / 60)) : 0
        s.streak = usage.streak
        let calendar = Calendar.current
        s.days = (0..<14).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            return Day(date: d, words: usage.words(on: d))
        }
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let recent = history.filter { $0.date >= cutoff && $0.mode != .ask }
        s.weekDictations = recent.count
        var byApp: [String: (Int, Int)] = [:]
        for item in recent {
            let name = item.appName.isEmpty ? "Other" : item.appName
            byApp[name, default: (0, 0)].0 += 1
            byApp[name, default: (0, 0)].1 += item.wordCount
        }
        s.apps = byApp.map { App(name: $0.key, dictations: $0.value.0, words: $0.value.1) }.sorted { $0.words > $1.words }.prefix(5).map { $0 }
        s.wordsCleaned = recent.reduce(0) { $0 + max(0, $1.raw.split(whereSeparator: \.isWhitespace).count - $1.wordCount) }
        s.lists = recent.filter { ListFormat.detect($0.text).kind != nil }.count
        if !recent.isEmpty { s.onDevicePercent = Int((Double(recent.filter(\.stayedOnDevice).count) / Double(recent.count) * 100).rounded()) }
        let latencies = recent.compactMap(\.latencyMs).sorted()
        if !latencies.isEmpty { s.medianLatencyMs = latencies[latencies.count / 2] }
        return s
    }
}

struct StatsView: View {
    @State private var summary: StatsSummary
    private let live: Bool

    init(preview: StatsSummary? = nil) {
        _summary = State(initialValue: preview ?? StatsSummary.current())
        live = preview == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your week").font(.system(size: 30, design: .serif))
                Spacer()
                if summary.streak > 1 {
                    Label("\(summary.streak)-day streak", systemImage: "flame.fill").foregroundStyle(.orange).font(.callout.weight(.semibold))
                }
            }
            HStack(spacing: 12) {
                tile("\(summary.weekWords.formatted())", "words spoken")
                tile(timeSaved(summary.weekMinutesSaved), "saved vs typing")
                tile(summary.speakingWPM > 0 ? "\(summary.speakingWPM) wpm" : "—", "your speaking speed")
                tile("\(summary.weekDictations)", "dictations")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 14 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(summary.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words))
                        .foregroundStyle(Brand.mint.gradient)
                        .cornerRadius(4)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 140)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where you talk most").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if summary.apps.isEmpty {
                        Text("Dictate in a few apps and they'll show up here.").foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(summary.apps) { app in
                        HStack {
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text("\(app.words.formatted()) words").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Freshflo did for you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    fact("scissors", "\(summary.wordsCleaned.formatted()) filler and repeated words removed")
                    fact("list.bullet", "\(summary.lists) list\(summary.lists == 1 ? "" : "s") formatted")
                    if summary.medianLatencyMs > 0 { fact("bolt.fill", "Text ready in \(String(format: "%.2f", Double(summary.medianLatencyMs) / 1000)) s (median)") }
                    fact("lock.fill", "\(summary.onDevicePercent)% stayed on this Mac")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text("All time: \(summary.allTimeWords.formatted()) words, \(timeSaved(summary.allTimeMinutesSaved)) saved. Counted on this Mac only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 640, height: 560)
        .background(Brand.backdrop)
        .environment(\.colorScheme, .light)
        .onAppear { if live { summary = StatsSummary.current() } }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.callout)
    }

    /// Made-up numbers for design review (CLI: --render-stats out.png).
    static var demo: StatsSummary {
        var s = StatsSummary()
        s.weekWords = 8_420; s.weekMinutesSaved = 162; s.weekDictations = 214; s.speakingWPM = 148; s.streak = 9
        s.allTimeWords = 61_300; s.allTimeMinutesSaved = 1_190
        let cal = Calendar.current
        let pattern = [320, 540, 0, 880, 1_020, 760, 410, 690, 1_240, 980, 0, 1_110, 1_350, 920]
        s.days = pattern.enumerated().map { i, w in .init(date: cal.date(byAdding: .day, value: i - 13, to: cal.startOfDay(for: Date()))!, words: w) }
        s.apps = [.init(name: "Slack", dictations: 88, words: 2_900), .init(name: "Cursor", dictations: 41, words: 2_310),
                  .init(name: "Gmail", dictations: 23, words: 1_640), .init(name: "Notion", dictations: 19, words: 980), .init(name: "WhatsApp", dictations: 43, words: 590)]
        s.wordsCleaned = 1_284; s.lists = 17; s.onDevicePercent = 22; s.medianLatencyMs = 410
        return s
    }

    private func timeSaved(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
