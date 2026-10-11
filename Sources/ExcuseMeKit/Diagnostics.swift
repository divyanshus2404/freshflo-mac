import AppKit
import Foundation

/// One line per dictation in ~/Library/Logs/ExcuseMe/dictations.jsonl: timings, engines and errors.
/// Never the words themselves (only counts), so the log is safe to share when reporting a problem.
struct DictationTrace: Codable {
    var date = Date()
    var app = ""
    var mode = ""
    var audioSeconds = 0.0
    var chunks = 0
    var transcriber = ""
    var cleanup = ""
    var transcribeMs = 0
    var polishMs = 0
    var insertMs = 0
    var totalMs = 0
    var words = 0
    var outcome = ""
    var error: String?
}

enum Diagnostics {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ExcuseMe", isDirectory: true)
    static var logURL: URL { directory.appendingPathComponent("dictations.jsonl") }
    private static let queue = DispatchQueue(label: "ExcuseMe.diagnostics")
    private static let maxBytes = 2 * 1024 * 1024

    static func record(_ trace: DictationTrace) {
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep the log small: rotate to .old once it passes 2 MB.
            if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("dictations.old.jsonl")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: logURL, to: old)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(trace) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: logURL)
            }
        }
    }

    /// Recent traces, newest first.
    static func recent(_ limit: Int = 200) -> [DictationTrace] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).reversed().compactMap {
            try? decoder.decode(DictationTrace.self, from: Data($0.utf8))
        }
    }

    /// A short plain-text summary (median latencies, error rate) for Settings and bug reports.
    static func summary() -> String {
        let traces = recent(200)
        guard !traces.isEmpty else { return "No dictations recorded yet." }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let ok = traces.filter { $0.error == nil }
        let failed = traces.count - ok.count
        return """
        Last \(traces.count) dictations · \(failed) failed
        Median: transcribe \(median(ok.map(\.transcribeMs))) ms · polish \(median(ok.map(\.polishMs))) ms · total \(median(ok.map(\.totalMs))) ms
        Slowest total: \(ok.map(\.totalMs).max() ?? 0) ms
        """
    }

    static func revealLog() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}
