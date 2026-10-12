import AppKit
import CryptoKit
import Security

/// Keeps everyone on the latest build without the Mac App Store.
/// Reads https://freshflo.vercel.app/updates.json, then downloads the new disk image, checks its SHA-256,
/// checks the app inside is signed by the same developer team as this copy, swaps it in place and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()
    static let feedURL = URL(string: ProcessInfo.processInfo.environment["FRESHFLO_UPDATE_FEED"] ?? "https://freshflo.vercel.app/updates.json")!

    struct Release: Decodable {
        var version: String
        var url: URL
        var sha256: String
        var notes: [String]
        var minimumSystemVersion: String?
    }

    private(set) var available: Release?
    private(set) var installing = false
    var onChange: (() -> Void)?
    private var timer: Timer?

    nonisolated static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in Task { await self?.check(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        do {
            var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Freshflo/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let systemOK = release.minimumSystemVersion.map { !Self.isNewer($0, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") } ?? true
            guard Self.isNewer(release.version, than: Self.currentVersion), systemOK else {
                available = nil
                onChange?()
                if userInitiated { inform("You're up to date", "Freshflo \(Self.currentVersion) is the newest version.") }
                return
            }
            available = release
            onChange?()
            let announced = UserDefaults.standard.string(forKey: "update.announced")
            if userInitiated || announced != release.version {
                UserDefaults.standard.set(release.version, forKey: "update.announced")
                offer(release)
            }
        } catch {
            if userInitiated { inform("Couldn't check for updates", "Check your internet connection and try again.") }
        }
    }

    func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Freshflo \(release.version) is available"
        let notes = release.notes.prefix(6).map { "• \($0)" }.joined(separator: "\n")
        alert.informativeText = "You have \(Self.currentVersion).\n\n\(notes)"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await install(release) }
        }
    }

    func install(_ release: Release) async {
        guard !installing else { return }
        installing = true
        onChange?()
        defer { installing = false; onChange?() }
        do {
            let (dmg, mount, newApp) = try await downloadAndVerify(release)
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

            let target = Bundle.main.bundleURL
            let folder = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                // Can't replace in place (e.g. a managed Mac): hand over the disk image instead.
                NSWorkspace.shared.open(dmg)
                inform("Almost there", "Drag the new Freshflo into Applications to replace the old one.")
                return
            }
            let staging = folder.appendingPathComponent(".Freshflo-\(release.version)-\(UUID().uuidString.prefix(6)).app")
            try run("/usr/bin/ditto", [newApp.path, staging.path])
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            relaunch(at: target)
        } catch {
            inform("Update didn't install", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Downloads the disk image, checks its SHA-256, mounts it and verifies the app's signature.
    func downloadAndVerify(_ release: Release) async throws -> (dmg: URL, mount: URL, app: URL) {
        let (downloaded, response) = try await URLSession.shared.download(from: release.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Freshflo-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else { throw UpdateError.checksum }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        let app = mount.appendingPathComponent("Freshflo.app")
        do { try verifySignature(of: app) } catch {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            throw error
        }
        return (dmg, mount, app)
    }

    /// CLI: `--check-update` fetches the feed, then downloads and verifies without installing.
    func dryRun() async -> String {
        do {
            var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Freshflo/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let newer = Self.isNewer(release.version, than: Self.currentVersion)
            let (_, mount, app) = try await downloadAndVerify(release)
            let inner = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            return "feed \(release.version) (\(newer ? "newer than" : "not newer than") \(Self.currentVersion)); checksum ok; signature ok; app inside is \(inner)"
        } catch {
            return "update check failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    enum UpdateError: LocalizedError {
        case download, checksum, signature(String), tool(String)
        var errorDescription: String? {
            switch self {
            case .download: return "The download failed. Please try again later."
            case .checksum: return "The download didn't match the published checksum, so it wasn't installed."
            case .signature(let why): return "The new version isn't signed by Freshflo's developer, so it wasn't installed. (\(why))"
            case .tool(let why): return why
            }
        }
    }

    /// The update must carry the same bundle ID and be signed by the same Apple developer team as the running app.
    private func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              let selfStatic = Self.staticCode(selfCode),
              SecCodeCopySigningInformation(selfStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw UpdateError.signature("this copy has no developer signature")
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.signature("unreadable")
        }
        var requirement: SecRequirement?
        let text = "identifier \"com.freshflo.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw UpdateError.signature("requirement") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signature("code \(status)") }
    }

    private static func staticCode(_ code: SecCode) -> SecStaticCode? {
        var out: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &out) == errSecSuccess ? out : nil
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw UpdateError.tool("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output.prefix(200))") }
        return output
    }

    private func relaunch(at app: URL) {
        let script = "sleep 1; /usr/bin/open \"\(app.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Numeric comparison: 0.10.0 is newer than 0.9.5.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// Shown once after an update, so people see what got better.
enum WhatsNew {
    static let notes: [String: [String]] = [
        "0.13.0": [
            "Settings is simpler: meeting notes and Claude/Cursor have their own Meetings tab, and sync and diagnostics live under Advanced.",
            "Setup now shows the extras (live captions, meeting notes, lists and emails, Claude and Cursor, Scratchpad, Your Week) with switches to turn them on.",
            "VoiceOver hears when Freshflo starts listening and what it typed.",
        ],
        "0.12.2": [
            "Automatic microphone: Freshflo picks the best mic that's connected (USB, then your Mac's, then a headset), skips system-audio devices like BlackHole, and follows you as devices come and go.",
            "Unplug a mic or connect AirPods mid-sentence and Freshflo carries on with the next mic without losing what you said.",
            "Call detection: when a Zoom, Teams, Meet or FaceTime call starts, Freshflo offers to take notes with one click.",
        ],
        "0.12.1": [
            "With AirPods or another Bluetooth headset connected, Freshflo now uses your Mac's microphone, so your first words aren't cut off and your music stays at full quality. Change it in Settings → General.",
            "If a microphone goes silent mid-dictation, Freshflo switches to the Mac's microphone instead of stopping.",
        ],
        "0.12.0": [
            "Speaker names in meeting notes: everyone else on the call is told apart by voice, and named when they introduce themselves.",
            "Scratchpad (menu → Scratchpad…): dictate notes to yourself. Anything dictated with no text field in front of you lands there too.",
            "Meeting notes: a live recording card shows both your mic and the call being heard, warns if the call isn't captured, and leaves music apps out.",
            "After a meeting: a grammatically clean transcript next to the original, Who said what, rename any speaker, and one-click follow-up email, Slack summary or action items.",
            "Amounts like \u{201C}two lakh fifty thousand rupees\u{201D} reliably become ₹2,50,000. Meeting transcripts no longer pick up a phantom \u{201C}Thank you\u{201D}.",
        ],
        "0.11.1": [
            "A calmer, sharper dictation bar: a row of dots that rises with your voice, shimmers while polishing, and draws a check when done.",
            "Five more indicator styles to choose from in Settings → General: Orb, Island, Equalizer, Glow line and Compact bar.",
        ],
        "0.11.0": [
            "Ask your meetings: \u{201C}What did we decide about pricing?\u{201D} answered from your notes, with the meetings it came from (Meeting Notes → Ask).",
            "Use Freshflo in Claude, Cursor and Claude Code: connect in Settings → General and ask them about your meetings.",
            "Email mode: in Mail, Outlook and Gmail you get a greeting line, short paragraphs and a sign-off.",
            "Say \u{201C}camel case user id\u{201D} or \u{201C}package dot json\u{201D} and get userId and package.json.",
            "Whisper mode: quiet speech is boosted automatically. 100 languages. Turn Freshflo off in chosen apps from the menu.",
            "Sync your dictionary, snippets and styles through iCloud Drive, or share them with your team through a shared folder.",
            "Your Week: words, time saved, speaking speed, streak and where you dictate most (menu → Your Week…).",
        ],
        "0.10.0": [
            "Stronger grammar: “I am having two brothers”, “since two days”, “Where you are going?”, “Me and him went”, “didn't went” and dozens more spoken slips come out as correct English, with or without AI.",
            "Faster through busy moments: if Groq's free tier is rate-limited, cleanup switches to another model instead of a weaker fallback.",
        ],
        "0.9.9": [
            "Smart lists: say \u{201C}first… second… third…\u{201D} for a numbered list, or \u{201C}bullet point…\u{201D} for bullets. Everything else stays as sentences.",
            "Live captions (menu → Live Captions): see your words as you speak and what Freshflo detects: a list, a question, a correction, filler words.",
            "A smaller, quieter dictation bar.",
        ],
        "0.9.8": [
            "Prompt mode: in Cursor, Claude, ChatGPT and Claude Code, rambling becomes a clear, structured prompt.",
            "Ten Indian languages, from Tamil to Punjabi, in and English out. Pick yours in Settings → General.",
            "Send Feedback… in the menu goes straight to the person who builds Freshflo.",
            "Optional: share anonymous daily counts and crash reports to help improve Freshflo (Settings → General).",
        ],
        "0.9.7": [
            "Grammar fixed, not just punctuation: \u{201C}he don't know nothing\u{201D} becomes \u{201C}he doesn't know anything\u{201D}.",
            "Stutters and repeats removed: \u{201C}I I think the the\u{201D} becomes \u{201C}I think the\u{201D}.",
            "Swear words cleaned up by default. Choose Clean it up, Mask or Keep in Settings → Style.",
            "Names close to ones in your Dictionary are spelled your way, even offline.",
        ],
        "0.9.6": [
            "A new setup assistant with a step-by-step sidebar and a live demo of what Freshflo does.",
            "Setup shows exactly which switch to turn on in System Settings, then moves on by itself.",
            "Freshflo can open when you log in, so it's always ready.",
            "A cheat sheet of the three keys when you finish.",
        ],
        "0.9.5": [
            "Works on every Mac with macOS 14 or later, Apple Silicon and Intel.",
            "No API key needed: Apple's built-in speech engine is the free default.",
            "A faster, friendlier setup that checks your talk key and the 🌐 key setting.",
            "Updates install themselves from now on.",
            "Your daily words, time saved and streak, right in the menu.",
        ],
    ]

    @MainActor
    static func showIfUpdated() {
        let defaults = UserDefaults.standard
        let current = Updater.currentVersion
        let last = defaults.string(forKey: "lastRunVersion")
        defaults.set(current, forKey: "lastRunVersion")
        guard let last, last != current, Updater.isNewer(current, than: last), let notes = notes[current] else { return }
        let alert = NSAlert()
        alert.messageText = "What's new in Freshflo \(current)"
        alert.informativeText = notes.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Nice")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
