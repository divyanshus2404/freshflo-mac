import Combine
import CommonCrypto
import CryptoKit
import Foundation

/// Sync by share code: the same dictionary, snippets and app styles on Mac, Windows and Android.
/// Everything is encrypted on this Mac with a key made from the code; freshflo.vercel.app only stores an id and scrambled bytes.
/// Format v1 is shared with freshflo_core::sync (Rust) and SyncCrypto.kt; see sync.rs for the spec.
enum SyncCrypto {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let salt = Data("freshflo-sync-v1".utf8)
    static let rounds: UInt32 = 200_000

    struct Payload: Codable, Equatable {
        var v = 1
        var dictionary: [String] = []
        var snippets: [SyncSnippet] = []
        var styles: [Style] = []
    }
    struct SyncSnippet: Codable, Equatable { var trigger: String; var text: String }
    struct Style: Codable, Equatable { var app: String; var name: String; var tone: String }

    struct Keys { let key: SymmetricKey; let id: String }

    /// Upper-case, drop dashes and spaces, read O as 0 and I/L as 1. Nil unless it's 16 valid characters.
    static func normalize(_ code: String) -> String? {
        let s = String(code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { c -> Character in
            switch c { case "O": return "0"; case "I", "L": return "1"; default: return c }
        })
        return s.count == 16 && s.allSatisfy(alphabet.contains) ? s : nil
    }

    static func pretty(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(4, code.count - i))])
        }.joined(separator: "-")
    }

    static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0 & 31)] })
    }

    static func keys(_ code: String) -> Keys? {
        guard let code = normalize(code) else { return nil }
        var master = [UInt8](repeating: 0, count: 64)
        let password = Array(code.utf8)
        let ok = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &master, master.count)
        }
        guard ok == kCCSuccess else { return nil }
        let id = SHA256.hash(data: Data(master[32...])).map { String(format: "%02x", $0) }.joined()
        return Keys(key: SymmetricKey(data: Data(master[..<32])), id: id)
    }

    static func seal(_ keys: Keys, _ payload: Payload) -> String? {
        guard let plain = try? JSONEncoder().encode(payload),
              let box = try? AES.GCM.seal(plain, using: keys.key, authenticating: salt) else { return nil }
        return box.combined?.base64EncodedString()
    }

    /// Nil when the data was made with a different code or was tampered with.
    static func open(_ keys: Keys, _ blob: String) -> Payload? {
        guard let data = Data(base64Encoded: blob.trimmingCharacters(in: .whitespacesAndNewlines)),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: keys.key, authenticating: salt) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: plain)
    }

    /// Union of both sides. Local wins for the same snippet trigger or app; words are de-duplicated ignoring case.
    static func merge(local: Payload, remote: Payload) -> Payload {
        var out = local
        var words = Set(local.dictionary.map { $0.lowercased() })
        for w in remote.dictionary where words.insert(w.lowercased()).inserted { out.dictionary.append(w) }
        var triggers = Set(local.snippets.map { $0.trigger.lowercased() })
        for s in remote.snippets where triggers.insert(s.trigger.lowercased()).inserted { out.snippets.append(s) }
        var apps = Set(local.styles.map { $0.app.lowercased() })
        for s in remote.styles where apps.insert(s.app.lowercased()).inserted { out.styles.append(s) }
        return out
    }

    static func same(_ a: Payload, _ b: Payload) -> Bool {
        Set(a.dictionary.map { $0.lowercased() }) == Set(b.dictionary.map { $0.lowercased() })
            && Set(a.snippets.map { $0.trigger.lowercased() + "\u{1}" + $0.text }) == Set(b.snippets.map { $0.trigger.lowercased() + "\u{1}" + $0.text })
            && Set(a.styles.map { $0.app.lowercased() + "\u{1}" + $0.tone }) == Set(b.styles.map { $0.app.lowercased() + "\u{1}" + $0.tone })
    }
}

/// Keeps this Mac in step with your other devices through the share code (kept in the Keychain).
final class ShareSync: ObservableObject {
    static let shared = ShareSync()
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["FRESHFLO_SYNC_URL"] ?? "https://freshflo.vercel.app/api/sync")!
    private static let account = "sync-code"

    @Published private(set) var code: String = Keychain.get(ShareSync.account)
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    private let settings = AppSettings.shared
    private var keys: SyncCrypto.Keys?
    private var watchers: Set<AnyCancellable> = []
    private var timer: Timer?
    private var applying = false

    var isOn: Bool { !code.isEmpty }

    func start() {
        Publishers.Merge3(settings.$dictionary.map { _ in () }, settings.$snippets.map { _ in () }, settings.$toneRules.map { _ in () })
            .dropFirst(3)
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncNow() }
            .store(in: &watchers)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.syncNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.syncNow() }
    }

    /// Turns sync on with a new code, or one from another device. Returns an error to show, or nil.
    @discardableResult
    func turnOn(code input: String? = nil) -> String? {
        let raw = input ?? SyncCrypto.newCode()
        guard let normal = SyncCrypto.normalize(raw) else { return "That code doesn't look right. It's 16 letters and numbers, like 7KQ2-9MXD-AB3C-DEFG." }
        Keychain.set(normal, for: Self.account)
        code = normal
        keys = nil
        lastError = nil
        syncNow()
        return nil
    }

    /// Stops syncing on this Mac. With `erase`, also deletes the encrypted copy on the server (other devices keep theirs).
    func turnOff(erase: Bool) {
        if erase, let k = currentKeys() {
            var req = URLRequest(url: Self.endpoint.appending(queryItems: [URLQueryItem(name: "id", value: k.id)]))
            req.httpMethod = "DELETE"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.set("", for: Self.account)
        code = ""
        keys = nil
        lastSynced = nil
        lastError = nil
    }

    private func currentKeys() -> SyncCrypto.Keys? {
        if keys == nil, isOn { keys = SyncCrypto.keys(code) }
        return keys
    }

    private var local: SyncCrypto.Payload {
        SyncCrypto.Payload(dictionary: settings.dictionary,
                           snippets: settings.snippets.map { .init(trigger: $0.trigger, text: $0.expansion) },
                           styles: settings.toneRules.map { .init(app: $0.bundleID, name: $0.appName, tone: $0.tone.rawValue) })
    }

    private func apply(_ p: SyncCrypto.Payload) {
        applying = true
        defer { applying = false }
        if p.dictionary != settings.dictionary { settings.dictionary = p.dictionary }
        var snippets = settings.snippets
        for s in p.snippets where !snippets.contains(where: { $0.trigger.lowercased() == s.trigger.lowercased() }) {
            snippets.append(Snippet(trigger: s.trigger, expansion: s.text))
        }
        if snippets != settings.snippets { settings.snippets = snippets }
        var rules = settings.toneRules
        for s in p.styles where !rules.contains(where: { $0.bundleID.lowercased() == s.app.lowercased() }) {
            // Only styles for apps that exist on a Mac (bundle ids); Windows and Android ones ride along on the server.
            guard s.app.contains("."), !s.app.lowercased().hasSuffix(".exe"), let tone = Tone(rawValue: s.tone) else { continue }
            rules.append(AppToneRule(bundleID: s.app, appName: s.name, tone: tone))
        }
        if rules != settings.toneRules { settings.toneRules = rules }
    }

    func syncNow() {
        guard !applying, !busy, isOn else { return }
        busy = true
        let code = self.code
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let keys = await MainActor.run(body: { self.currentKeys() }) else { return }
            do {
                let remote = try await Self.fetch(keys)
                let local = await MainActor.run { self.local }
                // Keep other platforms' styles: merge the remote copy in full, but only apply what fits a Mac.
                let merged = remote.map { SyncCrypto.merge(local: local, remote: $0) } ?? local
                await MainActor.run { if self.code == code { self.apply(merged) } }
                if remote == nil || !SyncCrypto.same(merged, remote!) { try await Self.upload(keys, merged) }
                await MainActor.run { self.lastSynced = Date(); self.lastError = nil; self.busy = false }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription; self.busy = false }
            }
        }
    }

    struct SyncError: LocalizedError {
        let errorDescription: String?
    }

    static func fetch(_ keys: SyncCrypto.Keys) async throws -> SyncCrypto.Payload? {
        let (data, response) = try await URLSession.shared.data(from: endpoint.appending(queryItems: [URLQueryItem(name: "id", value: keys.id)]))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let blob = body["data"] as? String else {
            throw SyncError(errorDescription: "Couldn't reach Freshflo sync. It'll retry.")
        }
        guard let payload = SyncCrypto.open(keys, blob) else { throw SyncError(errorDescription: "The synced data couldn't be unlocked with this code.") }
        return payload
    }

    static func upload(_ keys: SyncCrypto.Keys, _ payload: SyncCrypto.Payload) async throws {
        guard let blob = SyncCrypto.seal(keys, payload) else { throw SyncError(errorDescription: "Couldn't encrypt your data.") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": keys.id, "data": blob])
        let (_, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError(errorDescription: "Couldn't save to Freshflo sync. It'll retry.") }
    }
}
