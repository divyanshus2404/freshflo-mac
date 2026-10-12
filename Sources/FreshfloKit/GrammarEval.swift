import Foundation

/// `--grammar-eval cases.json [--cleanup auto|apple|api|rules]`: runs written transcripts through the real cleanup and checks
/// each result for phrases that must (and must not) appear. Used to measure and tune grammar correction.
enum GrammarEval {
    struct Case: Decodable {
        var raw: String
        var app: String?
        var must: [String]?
        var mustNot: [String]?
        var tag: String?
    }

    static func run(path: String, mode: CleanupMode?, settings: AppSettings, verbose: Bool, paceMs: Int = 0) async throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var passed = 0, byTag: [String: (Int, Int)] = [:], engines: [String: Int] = [:]
        var totalMs = 0
        for (i, c) in cases.enumerated() {
            if paceMs > 0, i > 0 { try await Task.sleep(nanoseconds: UInt64(paceMs) * 1_000_000) }
            var context = FocusContext()
            context.bundleID = c.app ?? "com.tinyspeck.slackmacgap"
            context.appName = context.bundleID.components(separatedBy: ".").last ?? ""
            let start = Date()
            let result = await Pipeline.polish(raw: c.raw, context: context, settings: settings, mode: mode)
            totalMs += Int(Date().timeIntervalSince(start) * 1000)
            engines[result.engine, default: 0] += 1
            let out = result.text.lowercased()
            let missing = (c.must ?? []).filter { !out.contains($0.lowercased()) }
            let present = (c.mustNot ?? []).filter { out.contains($0.lowercased()) }
            let ok = missing.isEmpty && present.isEmpty
            if ok { passed += 1 }
            let tag = c.tag ?? "other"
            byTag[tag] = ((byTag[tag]?.0 ?? 0) + (ok ? 1 : 0), (byTag[tag]?.1 ?? 0) + 1)
            if !ok || verbose {
                print("\(ok ? "✓" : "✗") #\(i + 1) [\(tag)] \(c.raw)")
                print("    → [\(result.engine)] \(result.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                if !missing.isEmpty { print("    missing: \(missing)") }
                if !present.isEmpty { print("    should not contain: \(present)") }
            }
        }
        print("\nby tag:")
        for (tag, (ok, n)) in byTag.sorted(by: { $0.key < $1.key }) { print("  \(tag): \(ok)/\(n)") }
        print("engines: \(engines)  avg \(cases.isEmpty ? 0 : totalMs / cases.count) ms")
        print("GRAMMAR \(passed)/\(cases.count)")
    }
}
