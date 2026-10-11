import Foundation

/// Keeps the audio of a failed dictation on disk so it survives network drops, crashes and restarts.
enum FailedStore {
    struct Meta: Codable {
        var appName: String
        var bundleID: String
        var mode: DictationMode
        var date: Date
    }

    private static let dir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExcuseMe/Failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var audioURL: URL { dir.appendingPathComponent("last.wav") }
    private static var metaURL: URL { dir.appendingPathComponent("last.json") }

    static func save(samples: [Float], context: FocusContext, mode: DictationMode) {
        try? AudioRecorder.wav(from: samples).write(to: audioURL, options: .atomic)
        let meta = Meta(appName: context.appName, bundleID: context.bundleID, mode: mode, date: Date())
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    static func load() -> (samples: [Float], context: FocusContext, mode: DictationMode)? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              Date().timeIntervalSince(meta.date) < 7 * 24 * 3600,
              let samples = try? AudioRecorder.load(url: audioURL), !samples.isEmpty else { return nil }
        var context = FocusContext()
        context.appName = meta.appName
        context.bundleID = meta.bundleID
        return (samples, context, meta.mode)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: metaURL)
    }
}
