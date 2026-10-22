import Foundation

/// `Freshflo --commitments-eval Benchmarks/commitments-eval.json [--runs 3] [--smart-model <id>] [--verbose]`
/// Scores Open commitments against hand-labelled meetings: is the same promise restated in a later meeting merged (and
/// different work kept apart), is an item a later meeting finished marked done (and a slipped one not), and does every
/// item get the right date. Run it once per model to compare them (Nemotron 3 Super vs Ultra).
enum CommitmentsEval {
    struct Scenario: Decodable {
        struct Notes: Decodable {
            let id: String
            let title: String
            /// Local time, "2026-10-05T18:00".
            let date: String
            let notes: String
        }

        struct Expect: Decodable {
            /// Each group lists phrases that pick out the items (by task text) that are one commitment.
            let groups: [[String]]
            /// Items a later meeting finished.
            let done: [String]?
            /// Items still open, including ones a later meeting said slipped.
            let open: [String]?
            /// Phrase → the date the item should end up with (YYYY-MM-DD).
            let due: [String: String]?
        }

        let name: String
        let meetings: [Notes]
        let expect: Expect
    }

    struct File: Decodable {
        let scenarios: [Scenario]
    }

    struct Score: Equatable {
        var truePairs = 0, predictedPairs = 0, correctPairs = 0
        var doneChecks = 0, doneCorrect = 0
        var dueChecks = 0, dueCorrect = 0
        /// Parsed items that are missing from the output (should always be 0).
        var lost = 0

        var mergePrecision: Double { predictedPairs == 0 ? 1 : Double(correctPairs) / Double(predictedPairs) }
        var mergeRecall: Double { truePairs == 0 ? 1 : Double(correctPairs) / Double(truePairs) }

        mutating func add(_ other: Score) {
            truePairs += other.truePairs; predictedPairs += other.predictedPairs; correctPairs += other.correctPairs
            doneChecks += other.doneChecks; doneCorrect += other.doneCorrect
            dueChecks += other.dueChecks; dueCorrect += other.dueCorrect
            lost += other.lost
        }
    }

    static func meetings(_ scenario: Scenario) -> [Meeting] {
        scenario.meetings.map {
            Meeting(id: $0.id, title: $0.title, date: date($0.date), duration: 1_800, status: .ready, appName: "",
                    notes: $0.notes, transcript: "", error: nil, onDevice: nil)
        }
    }

    static func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: text) ?? Commitments.isoDay(text) ?? Date()
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Which expected group each parsed item belongs to (nil: not labelled, left out of the pair counts).
    static func labels(_ items: [Commitments.Item], groups: [[String]]) -> [Int?] {
        items.map { item in
            let task = item.task.lowercased()
            return groups.firstIndex { $0.contains { task.contains($0.lowercased()) } }
        }
    }

    static func score(parsed: [Commitments.Item], output: [Commitments.Item], expect: Scenario.Expect) -> Score {
        var s = Score()
        let label = labels(parsed, groups: expect.groups)
        // The output item each parsed item ended up in.
        var placed = [Int?](repeating: nil, count: parsed.count)
        for (o, item) in output.enumerated() {
            for id in item.sourceIDs ?? [item.id] {
                if let i = parsed.firstIndex(where: { $0.id == id }) { placed[i] = o }
            }
        }
        s.lost = placed.filter { $0 == nil }.count
        // Pairwise: two items are "together" when they share an output item.
        for i in parsed.indices {
            for j in parsed.indices where j > i {
                guard let a = label[i], let b = label[j] else { continue }
                let truth = a == b
                let predicted = placed[i] != nil && placed[i] == placed[j]
                if truth { s.truePairs += 1 }
                if predicted { s.predictedPairs += 1 }
                if truth, predicted { s.correctPairs += 1 }
            }
        }
        func outputs(_ phrase: String) -> [Commitments.Item] {
            let p = phrase.lowercased()
            let hits = Set(parsed.indices.filter { parsed[$0].task.lowercased().contains(p) }.compactMap { placed[$0] })
            return hits.sorted().map { output[$0] }
        }
        for phrase in expect.done ?? [] {
            s.doneChecks += 1
            let o = outputs(phrase)
            if !o.isEmpty, o.allSatisfy({ $0.doneNote != nil }) { s.doneCorrect += 1 }
        }
        for phrase in expect.open ?? [] {
            s.doneChecks += 1
            let o = outputs(phrase)
            if !o.isEmpty, o.allSatisfy({ $0.doneNote == nil }) { s.doneCorrect += 1 }
        }
        for (phrase, wanted) in expect.due ?? [:] {
            s.dueChecks += 1
            let o = outputs(phrase)
            if !o.isEmpty, o.allSatisfy({ $0.dueDate.map(day) == wanted }) { s.dueCorrect += 1 }
        }
        return s
    }

    @MainActor
    static func run(path: String, settings: AppSettings, runs: Int, verbose: Bool) async throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        print("commitments eval: \(file.scenarios.count) scenarios × \(max(1, runs)) run(s) · \(ModelCredit.configured(settings) ?? "no model")\n")
        var total = Score()
        var seconds: [Double] = []
        var failed = 0
        for scenario in file.scenarios {
            let meetings = meetings(scenario)
            let parsed = Commitments.parse(meetings)
            for _ in 0..<max(1, runs) {
                let start = Date()
                do {
                    let result = try await Commitments.organize(parsed, meetings: meetings, settings: settings)
                    let elapsed = Date().timeIntervalSince(start)
                    seconds.append(elapsed)
                    let s = score(parsed: parsed, output: result.items, expect: scenario.expect)
                    total.add(s)
                    let name = scenario.name.padding(toLength: 42, withPad: " ", startingAt: 0)
                    print(name + String(format: " merge P %.2f R %.2f · done %d/%d · due %d/%d%@ · %.1f s",
                                        s.mergePrecision, s.mergeRecall, s.doneCorrect, s.doneChecks, s.dueCorrect, s.dueChecks,
                                        s.lost > 0 ? " · LOST \(s.lost)" : "", elapsed))
                    if verbose {
                        for item in result.items {
                            print("    \(item.task) — \(item.owner.isEmpty ? "-" : item.owner), \(item.dueDate.map(day) ?? "no date")"
                                  + (item.doneNote.map { " ✓ \($0)" } ?? "") + ((item.sourceIDs?.count ?? 1) > 1 ? " [merged \(item.sourceIDs!.count)]" : ""))
                        }
                    }
                } catch {
                    failed += 1
                    print("\(scenario.name): failed (\(error.localizedDescription))")
                }
            }
        }
        let p = total.mergePrecision, r = total.mergeRecall
        let sorted = seconds.sorted()
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%% (%d/%d)", Double(a) / Double(b) * 100, a, b) }
        print("""

        merge precision \(String(format: "%.2f", p)) · recall \(String(format: "%.2f", r)) · F1 \(String(format: "%.2f", p + r == 0 ? 0 : 2 * p * r / (p + r)))
        done / not done \(pct(total.doneCorrect, total.doneChecks)) · due dates \(pct(total.dueCorrect, total.dueChecks)) · items lost \(total.lost) · failed runs \(failed)
        latency median \(sorted.isEmpty ? "-" : String(format: "%.1f s", sorted[sorted.count / 2])) · worst \(sorted.last.map { String(format: "%.1f s", $0) } ?? "-")
        model \(Cleanup.lastModel ?? "-")
        """)
    }
}
