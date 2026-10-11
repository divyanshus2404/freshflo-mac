import AppKit
import SwiftUI

/// First-run setup: permissions → engine → shortcut → a practice dictation. Reopen from the menu (Setup Guide…).
struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var permissions = PermissionsModel()
    @State private var step = 0
    @State private var keyStatus: String?
    @State private var testingKey = false
    @State private var practice = ""
    @State private var historyCountAtPractice = 0
    @State private var localStatus = ""
    @State private var downloading = false

    private let steps = ["Welcome", "Permissions", "Engine", "Shortcut", "Try it"]

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 22)
                .padding(.horizontal, 32)
            Group {
                switch step {
                case 0: welcome
                case 1: permissionsStep
                case 2: engineStep
                case 3: shortcutStep
                default: tryItStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Welcome to ExcuseMe").font(.largeTitle.weight(.semibold))
            Text("Hold a key, speak, and polished text appears wherever your cursor is: in any app.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                bullet("waveform", "Dictate anywhere, 4× faster than typing")
                bullet("wand.and.stars", "Fillers removed, self-corrections fixed, formatted for each app")
                bullet("lock.shield", "Private: an on-device mode where nothing leaves your Mac")
            }
            .padding(.top, 6)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Two permissions", "ExcuseMe needs these to hear you and type for you. Nothing is recorded unless you hold the key.")
            permissionCard(
                icon: "mic.fill", name: "Microphone", detail: "To hear you while you hold the dictation key.",
                granted: permissions.microphone == .authorized
            ) {
                if permissions.microphone == .notDetermined {
                    Permissions.requestMicrophone { _ in permissions.refresh() }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            }
            permissionCard(
                icon: "accessibility", name: "Accessibility",
                detail: "To notice the dictation key in any app and paste the text where your cursor is.",
                granted: permissions.accessibility
            ) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if !permissions.accessibility {
                Text("In System Settings, turn on the switch next to ExcuseMe. This screen updates on its own.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Choose how speech is transcribed", "You can change this any time in Settings.")
            engineOption(
                selected: settings.provider == .groq, icon: "bolt.fill", name: "Groq (recommended)",
                detail: "Fastest and most accurate. Free API key, takes a minute."
            ) { settings.provider = .groq }
            engineOption(
                selected: settings.provider == .local, icon: "lock.shield.fill", name: "On-device",
                detail: "Free, private and offline. A little less accurate for names and accents."
            ) {
                settings.provider = .local
                refreshLocal()
            }
            if settings.provider == .groq {
                HStack {
                    SecureField("", text: $settings.apiKey, prompt: Text("Paste your Groq key (gsk_…)"))
                        .textFieldStyle(.roundedBorder)
                    Button(testingKey ? "Testing…" : "Test") { testKey() }.disabled(testingKey || settings.apiKey.isEmpty)
                }
                HStack {
                    if let keyStatus { Text(keyStatus).font(.callout).foregroundStyle(keyStatus.hasPrefix("✓") ? .green : .red) }
                    Spacer()
                    Link("Get a free key →", destination: URL(string: "https://console.groq.com/keys")!)
                }
            } else if settings.provider == .local {
                HStack {
                    Text(localStatus.isEmpty ? "Checking model…" : "Model: \(localStatus)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if localStatus != "Ready" {
                        Button(downloading ? "Downloading…" : "Download model") { downloadLocal() }.disabled(downloading)
                    }
                }
            }
        }
        .onAppear(perform: refreshLocal)
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Your dictation key", "Hold it to talk, release to insert. Tap it once for hands-free, then tap again to finish.")
            Picker("Dictation key", selection: $settings.hotkey) {
                ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.hotkey == .fn {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → **Do Nothing**, so macOS doesn't open the emoji picker.")
                        .font(.callout)
                    Spacer()
                    Button("Open") { Permissions.openKeyboardSettings() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }
            Text("Also: hold \(settings.hotkey.shortLabel) + Control to edit by voice, \(settings.hotkey.shortLabel) + Shift to ask a question.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if history.items.count > historyCountAtPractice {
                title("🎉 It works", "That's all there is to it. ExcuseMe lives in your menu bar.")
                if let last = history.items.first {
                    Text("“\(last.text)”")
                        .font(.title3)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            } else {
                title("Try it", "Click in the box, hold \(settings.hotkey.shortLabel), say something like “um, hey, this is my first dictation, no wait, my first test”, then let go.")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                    .frame(height: 120)
                if practice.isEmpty {
                    Text("Click here, then hold \(settings.hotkey.shortLabel) and speak…")
                        .foregroundStyle(.tertiary)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            if !permissions.accessibility || permissions.microphone != .authorized {
                Label("Permissions are still missing, so dictation won't work yet. Go back to step 2.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onAppear { historyCountAtPractice = history.items.count }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < steps.count - 1 {
                if step == 1, !(permissions.accessibility && permissions.microphone == .authorized) {
                    Button("Skip for now") { step += 1 }.buttonStyle(.borderless)
                }
                Button(step == 0 ? "Get started" : "Continue") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 2 && !settings.isReady)
            } else {
                Button("Finish", action: onFinish).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pieces

    private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.title.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20) }
    }

    private func permissionCard(icon: String, name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private func engineOption(selected: Bool, icon: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func testKey() {
        testingKey = true
        let endpoint = settings.endpoint
        Task { @MainActor in
            do {
                try await OpenAICompatible.verify(endpoint)
                keyStatus = "✓ Key works"
            } catch {
                keyStatus = error.localizedDescription
            }
            testingKey = false
        }
    }

    private func refreshLocal() {
        let language = settings.language
        Task { @MainActor in localStatus = await LocalSpeech.status(language: language) }
    }

    private func downloadLocal() {
        downloading = true
        let language = settings.language
        Task { @MainActor in
            try? await LocalSpeech.downloadModel(language: language)
            downloading = false
            LivePreview.prepare(language: language)
            refreshLocal()
        }
    }
}
