import Combine
import Foundation

/// Keeps your dictionary, snippets and per-app styles the same on every Mac (through iCloud Drive), or shares them with a team
/// (through any shared folder: Dropbox, Google Drive, OneDrive). No account and no Freshflo server: one JSON file in a folder you choose.
/// Merging only adds: a word, snippet or app style from any Mac shows up everywhere; your own edits always win.
final class FolderSync: ObservableObject {
    static let shared = FolderSync()
    static let fileName = "Freshflo Shared.json"

    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Freshflo", isDirectory: true)
    }
    static var iCloudAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudFolder.deletingLastPathComponent().path)
    }

    struct Payload: Codable {
        var version = 1
        var updated = Date()
        var dictionary: [String] = []
        var snippets: [Snippet] = []
        var toneRules: [AppToneRule] = []
    }

    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?

    private let settings = AppSettings.shared
    private var watchers: Set<AnyCancellable> = []
    private var timer: Timer?
    private var applying = false

    func start() {
        Publishers.Merge3(settings.$dictionary.map { _ in () }, settings.$snippets.map { _ in () }, settings.$toneRules.map { _ in () })
            .dropFirst(3)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncNow() }
            .store(in: &watchers)
        settings.$syncFolder
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncNow() } }
            .store(in: &watchers)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.syncNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.syncNow() }
    }

    /// Reads the shared file, merges it into this Mac's settings, and writes the union back.
    func syncNow() {
        guard !applying, !settings.syncFolder.isEmpty else { return }
        let folder = URL(fileURLWithPath: settings.syncFolder, isDirectory: true)
        let file = folder.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let remote = Self.read(file)
            let merged = Self.merge(local: Payload(dictionary: settings.dictionary, snippets: settings.snippets, toneRules: settings.toneRules), remote: remote)
            applying = true
            if merged.dictionary != settings.dictionary { settings.dictionary = merged.dictionary }
            if merged.snippets != settings.snippets { settings.snippets = merged.snippets }
            if merged.toneRules != settings.toneRules { settings.toneRules = merged.toneRules }
            applying = false
            if remote == nil || !Self.sameContent(merged, remote!) { try Self.write(merged, to: file) }
            lastSynced = Date()
            lastError = nil
        } catch {
            applying = false
            lastError = error.localizedDescription
        }
    }

    static func read(_ file: URL) -> Payload? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    static func write(_ payload: Payload, to file: URL) throws {
        var p = payload
        p.updated = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(p).write(to: file, options: .atomic)
    }

    /// Union of both sides. Local wins for the same snippet trigger or app; words are de-duplicated ignoring case.
    static func merge(local: Payload, remote: Payload?) -> Payload {
        guard let remote else { return local }
        var out = local
        var words = Set(local.dictionary.map { $0.lowercased() })
        for w in remote.dictionary where !words.contains(w.lowercased()) {
            out.dictionary.append(w)
            words.insert(w.lowercased())
        }
        var triggers = Set(local.snippets.map { $0.trigger.lowercased() })
        for s in remote.snippets where !triggers.contains(s.trigger.lowercased()) {
            out.snippets.append(s)
            triggers.insert(s.trigger.lowercased())
        }
        var apps = Set(local.toneRules.map(\.bundleID))
        for r in remote.toneRules where !apps.contains(r.bundleID) {
            out.toneRules.append(r)
            apps.insert(r.bundleID)
        }
        return out
    }

    private static func sameContent(_ a: Payload, _ b: Payload) -> Bool {
        Set(a.dictionary.map { $0.lowercased() }) == Set(b.dictionary.map { $0.lowercased() })
            && Set(a.snippets.map { $0.trigger.lowercased() + "\u{1}" + $0.expansion }) == Set(b.snippets.map { $0.trigger.lowercased() + "\u{1}" + $0.expansion })
            && Set(a.toneRules.map { $0.bundleID + $0.tone.rawValue }) == Set(b.toneRules.map { $0.bundleID + $0.tone.rawValue })
    }
}
