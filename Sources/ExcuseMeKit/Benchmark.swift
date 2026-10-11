import Foundation

/// Head-to-head dictation benchmark (CLI: `--benchmark`). Runs every case in Benchmarks/cases.json through
/// the real pipeline, scores word error rate and formatting checks, and can score another app's outputs too.
@MainActor
enum Benchmark {
    struct Case: Decodable {
        var id: String
        var speak: String?
        var reference: String
        var voice: String?
        var vocab: [String]?
        var app: String?
        var region: String?
        var writeIn: String?
        var command: String?
        var selection: String?
        var mustContain: [String]?
        var mustNotContain: [String]?
        var mustEndWith: String?
        var mustNotEndWith: String?
    }

    struct Score: Encodable {
        var id: String
        var output: String
        var wer: Double
        var checksPassed: Int
        var checksTotal: Int
        var failedChecks: [String]
        var latencyMs: Int?
    }

    static func run(directory: URL, compareFile: URL?) async throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
        let settings = AppSettings.shared
        let saved = (settings.outputLanguage, settings.regionalFormat)
        defer { (settings.outputLanguage, settings.regionalFormat) = saved }

        var ours: [Score] = []
        for c in cases {
            settings.outputLanguage = c.writeIn ?? ""
            settings.regionalFormat = RegionalFormat(rawValue: c.region ?? "") ?? .none
            let start = Date()
            var output: String
            do {
                if let instruction = c.command {
                    output = try await Pipeline.command(instruction: instruction, selection: c.selection ?? "", context: FocusContext(), settings: settings)
                } else {
                    let audio = directory.appendingPathComponent("audio/\(c.id).m4a")
                    let samples = AudioRecorder.trimSilence(try AudioRecorder.load(url: audio)).samples
                    let transcript = try await Pipeline.transcribe(samples, settings: settings, extraVocabulary: c.vocab ?? [])
                    var context = FocusContext()
                    context.bundleID = c.app ?? ""
                    context.appName = c.app.map { $0.components(separatedBy: ".").last ?? $0 } ?? ""
                    output = await Pipeline.polish(raw: transcript.text, context: context, settings: settings, extraVocabulary: c.vocab ?? []).text
                }
            } catch {
                output = "⚠︎ \(error.localizedDescription)"
            }
            var score = Self.score(c, output: output)
            score.latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            ours.append(score)
            print("  \(c.id): \(score.checksPassed)/\(score.checksTotal) checks, WER \(percent(score.wer)), \(score.latencyMs ?? 0) ms")
        }

        var theirs: [Score]?
        if let compareFile {
            let outputs = parseOutputs(try String(contentsOf: compareFile, encoding: .utf8))
            theirs = cases.map { Self.score($0, output: outputs[$0.id] ?? "") }
        }

        let report = markdown(cases: cases, ours: ours, theirs: theirs, otherName: compareFile.map { $0.deletingPathExtension().lastPathComponent } ?? "")
        let reportURL = directory.appendingPathComponent("REPORT.md")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ours).write(to: directory.appendingPathComponent("results-excuseme.json"))
        print("\n" + report)
        print("Saved \(reportURL.path)")
    }

    /// Accepts "id: output" lines (blank lines and # comments ignored).
    static func parseOutputs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let id = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            result[id] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func score(_ c: Case, output: String) -> Score {
        var failed: [String] = []
        var total = 0
        let lower = " " + output.lowercased() + " "
        for s in c.mustContain ?? [] {
            total += 1
            if !output.contains(s) { failed.append("missing “\(s)”") }
        }
        for s in c.mustNotContain ?? [] {
            total += 1
            let needle = s.lowercased()
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: needle.trimmingCharacters(in: .whitespaces)) + "(?![a-z])"
            if lower.range(of: pattern, options: .regularExpression) != nil { failed.append("contains “\(s.trimmingCharacters(in: .whitespaces))”") }
        }
        if let end = c.mustEndWith {
            total += 1
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end) { failed.append("should end with “\(end)”") }
        }
        if let end = c.mustNotEndWith {
            total += 1
            if output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end) { failed.append("shouldn't end with “\(end)”") }
        }
        return Score(id: c.id, output: output, wer: wer(reference: c.reference, hypothesis: output),
                     checksPassed: total - failed.count, checksTotal: total, failedChecks: failed)
    }

    /// Word error rate on normalized text (case, punctuation and common number/unit spellings ignored).
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    static func normalize(_ s: String) -> [String] {
        var t = s.lowercased()
        for (a, b) in [("p.m.", "pm"), ("a.m.", "am"), ("%", " percent"), ("₹", " rupees "), ("’", "'"), ("@", " at "), (".com", " dot com")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1$2", options: .regularExpression)
        return t.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }

    private static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private static func markdown(cases: [Case], ours: [Score], theirs: [Score]?, otherName: String) -> String {
        func totals(_ s: [Score]) -> (checks: String, wer: String) {
            let passed = s.reduce(0) { $0 + $1.checksPassed }, all = s.reduce(0) { $0 + $1.checksTotal }
            let audioScores = zip(cases, s).filter { $0.0.command == nil }.map(\.1)
            let meanWER = audioScores.map(\.wer).reduce(0, +) / Double(max(1, audioScores.count))
            return ("\(passed)/\(all)", percent(meanWER))
        }
        let latencies = ours.compactMap(\.latencyMs).sorted()
        var md = "# Dictation benchmark — \(Date().formatted(date: .abbreviated, time: .shortened))\n\n"
        let o = totals(ours)
        md += "| | ExcuseMe" + (theirs != nil ? " | \(otherName)" : "") + " |\n|---|---" + (theirs != nil ? "|---" : "") + "|\n"
        md += "| Formatting checks passed | \(o.checks)" + (theirs.map { " | \(totals($0).checks)" } ?? "") + " |\n"
        md += "| Mean word error rate (audio cases) | \(o.wer)" + (theirs.map { " | \(totals($0).wer)" } ?? "") + " |\n"
        md += "| Median latency (release → final text) | \(latencies.isEmpty ? 0 : latencies[latencies.count / 2]) ms" + (theirs != nil ? " | n/a" : "") + " |\n\n"
        md += "## Per case\n\n"
        for (i, c) in cases.enumerated() {
            let s = ours[i]
            md += "**\(c.id)** — reference: \(c.reference)\n"
            md += "- ExcuseMe (\(s.checksPassed)/\(s.checksTotal), WER \(percent(s.wer))): \(s.output)\(s.failedChecks.isEmpty ? "" : " ⚠︎ " + s.failedChecks.joined(separator: "; "))\n"
            if let t = theirs?[i] {
                md += "- \(otherName) (\(t.checksPassed)/\(t.checksTotal), WER \(percent(t.wer))): \(t.output.isEmpty ? "_(no output)_" : t.output)\(t.failedChecks.isEmpty ? "" : " ⚠︎ " + t.failedChecks.joined(separator: "; "))\n"
            }
            md += "\n"
        }
        return md
    }
}
