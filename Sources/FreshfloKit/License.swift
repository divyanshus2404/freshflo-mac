import CryptoKit
import Foundation

/// Freshflo Pro licences: a signed key that the app checks offline (no account, no server call, works forever).
///
/// A key looks like `FF1-<payload>.<signature>`: the payload is JSON (who, which plan, until when), base64url;
/// the signature is Ed25519 over the payload bytes, made with a private key that never ships in the app.
struct License: Codable, Equatable {
    var id: String
    var to: String            // name or email of the buyer, shown in Settings
    var plan: Plan
    var seats: Int
    var issued: Double        // unix seconds
    var expires: Double       // unix seconds; 0 = never (lifetime)

    enum Plan: String, Codable { case pro, lifetime, team }

    var isExpired: Bool { expires > 0 && Date().timeIntervalSince1970 > expires }
    var planLabel: String {
        switch plan {
        case .pro: return "Freshflo Pro"
        case .lifetime: return "Freshflo Pro · Lifetime"
        case .team: return "Freshflo Team · \(seats) seats"
        }
    }

    // MARK: Verification

    /// Ed25519 public key (raw, base64). The matching private key lives only with the publisher.
    static let publicKey = "Q9pcLKyDw/uicch9UHZ9fsvIVas8EOyMBjeB5utCpAc="

    enum Problem: Error, Equatable { case format, signature, expired }

    static func verify(_ key: String, publicKey: String = publicKey) -> Result<License, Problem> {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix("FF1-") else { return .failure(.format) }
        let parts = k.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = base64url(String(parts[0])), let sig = base64url(String(parts[1])),
              let raw = Data(base64Encoded: publicKey), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return .failure(.format) }
        guard pub.isValidSignature(sig, for: payload) else { return .failure(.signature) }
        guard let lic = try? JSONDecoder().decode(License.self, from: payload) else { return .failure(.format) }
        return lic.isExpired ? .failure(.expired) : .success(lic)
    }

    private static func base64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// What the installed licence unlocks.
@MainActor
final class Pro: ObservableObject {
    static let shared = Pro()

    /// During the beta every Pro feature is free for everyone. Flip to true when paid plans launch;
    /// nothing else needs to change.
    nonisolated static let enforced = false

    @Published private(set) var license: License?
    @Published private(set) var lastError: String?

    private static let keychainAccount = "license"

    private init() {
        let stored = Keychain.get(Self.keychainAccount)
        if !stored.isEmpty, case .success(let l) = License.verify(stored) { license = l }
    }

    var isActive: Bool { license.map { !$0.isExpired } ?? false }

    /// Free for everyone while `enforced` is false; otherwise needs an active licence.
    func allows(_ feature: Feature) -> Bool { !Self.enforced || isActive }

    enum Feature: String, CaseIterable {
        case cloudWithoutKey, unlimitedMeetings, commandAndAsk, translation, sync, dictionaryPacks
        var label: String {
            switch self {
            case .cloudWithoutKey: return "Freshflo Cloud: fastest dictation with no API key"
            case .unlimitedMeetings: return "Unlimited meeting notes with speaker names"
            case .commandAndAsk: return "Command and Ask modes"
            case .translation: return "Speak one language, write another"
            case .sync: return "Sync across your Macs"
            case .dictionaryPacks: return "Dictionary packs (medical, legal, developer)"
            }
        }
    }

    /// Free plan allowance for meetings each month (used only when `enforced`).
    static let freeMeetingsPerMonth = 3

    @discardableResult
    func activate(_ key: String) -> Bool {
        switch License.verify(key) {
        case .success(let l):
            Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keychainAccount)
            license = l
            lastError = nil
            return true
        case .failure(let p):
            lastError = switch p {
            case .format: "That doesn't look like a Freshflo licence key. Paste the whole key, starting with FF1-."
            case .signature: "This key isn't valid. Check you copied all of it, or contact support."
            case .expired: "This licence has expired. Renew it to keep Pro."
            }
            return false
        }
    }

    func deactivate() {
        Keychain.set("", for: Self.keychainAccount)
        license = nil
    }
}

import SwiftUI

/// Settings → General → Freshflo Pro: licence status, paste a key, or see the plans.
struct ProSection: View {
    @ObservedObject private var pro = Pro.shared
    @State private var key = ""

    var body: some View {
        Section("Freshflo Pro") {
            if let l = pro.license {
                LabeledContent(l.planLabel) {
                    Label("Active", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Text("Licensed to \(l.to)" + (l.expires > 0 ? " · renews \(Date(timeIntervalSince1970: l.expires).formatted(date: .abbreviated, time: .omitted))" : " · never expires"))
                    .font(.callout).foregroundStyle(.secondary)
                Button("Remove Licence From This Mac", role: .destructive) { pro.deactivate() }
            } else {
                if !Pro.enforced {
                    Label("Free during the beta: every Pro feature is unlocked.", systemImage: "gift").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Paste your licence key (FF1-…)", text: $key).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    Button("Activate") { if pro.activate(key) { key = "" } }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let e = pro.lastError { Text(e).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Text("Checked on this Mac. No account, works offline.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("See Plans…") { NSWorkspace.shared.open(URL(string: "https://freshflo.vercel.app/pricing")!) }
                }
            }
        }
    }
}
