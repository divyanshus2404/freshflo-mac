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
        /// "Write in" for this case ("English"); none means as spoken, so results never depend on your own settings.
        var writeIn: String?
        var region: String?
    }

    static func run(path: String, mode: CleanupMode?, settings: AppSettings, verbose: Bool, paceMs: Int = 0) async throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var passed = 0, byTag: [String: (Int, Int)] = [:], engines: [String: Int] = [:]
        var totalMs = 0
        let saved = (settings.outputLanguage, settings.regionalFormat)
        defer { (settings.outputLanguage, settings.regionalFormat) = saved }
        for (i, c) in cases.enumerated() {
            settings.outputLanguage = c.writeIn ?? ""
            settings.regionalFormat = RegionalFormat(rawValue: c.region ?? "") ?? .none
            if paceMs > 0, i > 0 { try await Task.sleep(nanoseconds: UInt64(paceMs) * 1_000_000) }
            var context = FocusContext()
            context.bundleID = c.app ?? "com.tinyspeck.slackmacgap"
            context.appName = context.bundleID.components(separatedBy: ".").last ?? ""
            let start = Date()
            let result = await Pipeline.polish(raw: c.raw, context: context, settings: settings, mode: mode)
            totalMs += Int(Date().timeIntervalSince(start) * 1000)
            engines[result.engine, default: 0] += 1
            // Compare code units, not whole characters: "संध्याकाळ" is inside "संध्याकाळी" even though the last letter
            // and its vowel sign form one character.
            let out = result.text.lowercased() as NSString
            let has = { (needle: String) in out.range(of: needle.lowercased(), options: .literal).location != NSNotFound }
            // "late|delayed": either one is right.
            let missing = (c.must ?? []).filter { !$0.split(separator: "|").contains { has(String($0)) } }
            let present = (c.mustNot ?? []).filter { has($0) }
            // "Write in" cases must really come out in that language (English: no Hinglish or other-script words left).
            let target = c.writeIn ?? ""
            let wrongLanguage = !target.isEmpty && !(target == "English" ? LanguageID.alreadyIn(result.text, target: target) : LanguageID.matches(result.text, target: target))
            let ok = missing.isEmpty && present.isEmpty && !wrongLanguage
            if ok { passed += 1 }
            let tag = c.tag ?? "other"
            byTag[tag] = ((byTag[tag]?.0 ?? 0) + (ok ? 1 : 0), (byTag[tag]?.1 ?? 0) + 1)
            if !ok || verbose {
                print("\(ok ? "✓" : "✗") #\(i + 1) [\(tag)] \(c.raw)")
                print("    → [\(result.engine)] \(result.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                if !missing.isEmpty { print("    missing: \(missing)") }
                if !present.isEmpty { print("    should not contain: \(present)") }
                if wrongLanguage { print("    not written in \(target)") }
            }
        }
        print("\nby tag:")
        for (tag, (ok, n)) in byTag.sorted(by: { $0.key < $1.key }) { print("  \(tag): \(ok)/\(n)") }
        print("engines: \(engines)  avg \(cases.isEmpty ? 0 : totalMs / cases.count) ms")
        print("GRAMMAR \(passed)/\(cases.count)")
    }
}
