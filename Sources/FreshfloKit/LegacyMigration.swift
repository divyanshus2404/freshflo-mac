import Foundation
import Security

/// One-time move from the app's previous name (ExcuseMe, bundle ID com.excuseme.app): settings, API keys,
/// history, meetings, failed audio and logs. Runs before anything reads settings. Old data is copied or moved,
/// never deleted, so the previous app keeps working if it's still installed.
public enum LegacyMigration {
    static let oldBundleID = "com.excuseme.app"
    static let oldFolder = "ExcuseMe"
    private static let doneKey = "migrated.fromExcuseMe"
    /// Set when settings came over from the old app. macOS ties permissions to the bundle ID,
    /// so setup reopens on the permissions step instead of the welcome screen.
    static let needsPermissionsKey = "migrated.needsPermissions"

    public static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty {
            for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: needsPermissionsKey)
        }

        for provider in Provider.allCases where Keychain.get(provider.rawValue).isEmpty {
            if let key = oldKey(provider.rawValue), !key.isEmpty { Keychain.set(key, for: provider.rawValue) }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        move(home.appendingPathComponent("Library/Application Support/\(oldFolder)"),
             to: home.appendingPathComponent("Library/Application Support/Freshflo"))
        move(home.appendingPathComponent("Library/Logs/\(oldFolder)"),
             to: home.appendingPathComponent("Library/Logs/Freshflo"))
    }

    private static func oldKey(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldBundleID,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Moves a folder only when the new location doesn't exist yet, so nothing is ever overwritten.
    private static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: from, to: to)
    }
}
