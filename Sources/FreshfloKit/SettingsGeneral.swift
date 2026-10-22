import AppKit
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var permissions = PermissionsModel()
    @State private var keyStatus: KeyStatus = .idle
    @State private var tryText = ""
    @State private var devices: [AudioDevice] = []
    @State private var localStatus = "Checking…"
    @State private var downloading = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum KeyStatus: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    private var talkHelp: String {
        let k = settings.talkKeyLabel
        let cancel = settings.shortcut(.cancel).map { " Press \($0.label) to cancel." } ?? ""
        switch settings.talkMode {
        case .holdOrTap: return "Hold \(k) to talk and let go to insert. Tap it once for hands-free, then tap again to finish.\(cancel)"
        case .hold: return "Hold \(k) while you talk; let go to insert. Quick taps are ignored.\(cancel)"
        case .toggle: return "Press \(k) once to start and again to insert. No need to hold.\(cancel)"
        case .doubleTap: return "Hold \(k) to talk. Double-tap it for hands-free, then press once to finish.\(cancel)"
        }
    }

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $tryText)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                    if tryText.isEmpty {
                        Text("Click here, hold \(settings.talkKeyLabel) and say something…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            } header: {
                HStack {
                    Text("Try it")
                    Spacer()
                    if isFullyPrivate {
                        Label("100% on-device", systemImage: "lock.shield.fill").foregroundStyle(.green).font(.caption)
                    }
                }
            }

            Section("Shortcut") {
                Picker("Talk key", selection: $settings.hotkey) {
                    ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.talkCombo != nil)
                LabeledContent("Or a key combination") {
                    ShortcutRecorder(combo: $settings.talkCombo, taken: { settings.owner(of: $0, exceptTalk: true) })
                }
                Picker("How it works", selection: $settings.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.label).tag($0) }
                }
                Text(talkHelp).font(.callout).foregroundStyle(.secondary)
                if settings.talkMode != .hold {
                    Toggle("Hands-free: finish when I stop talking", isOn: $settings.autoStopHandsFree)
                    if settings.autoStopHandsFree {
                        LabeledContent("Wait after I stop") {
                            HStack {
                                Slider(value: $settings.handsFreePause, in: 1.5...5, step: 0.5).frame(width: 160)
                                Text(String(format: "%.1f s", settings.handsFreePause)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Text("Freshflo listens for your voice, not just sound: typing or a fan won't keep it going, and it waits longer if you trail off with “and…” or “so…”.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Toggle("Command mode: hold \(settings.talkKeyLabel) + Control", isOn: $settings.commandModeEnabled)
                Toggle("Ask mode: hold \(settings.talkKeyLabel) + Shift", isOn: $settings.askModeEnabled)
                if settings.askModeEnabled {
                    Text("Ask about anything (or the selected text) and get an answer card, or say “remind me to call Rahul at 5”, “add lunch with Priya Friday 1pm to my calendar”, “email Sam that I'll be late”, “open Figma”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if settings.commandModeEnabled {
                    Text("Select text and say “make this more formal” or “translate to Hindi”, or with nothing selected say “write a polite reply declining the invite”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if settings.hotkey == .fn {
                    HStack {
                        Text("Set “Press 🌐 key to” → “Do Nothing” so macOS doesn't open the emoji picker.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Keyboard Settings…") { Permissions.openKeyboardSettings() }
                    }
                }
            }

            Section("More shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorder(combo: Binding(get: { settings.shortcut(action) }, set: { settings.setShortcut(action, $0) }),
                                         allowBare: action == .cancel,
                                         taken: { settings.owner(of: $0, except: action) })
                    }
                }
                Text("Work in every app. Cancel only takes the key while you're dictating, so Esc keeps working everywhere else.")
                    .font(.callout).foregroundStyle(.secondary)
                if settings.talkCombo != nil || !settings.shortcuts.isEmpty || !settings.clearedShortcuts.isEmpty || settings.talkMode != .holdOrTap {
                    Button("Reset shortcuts") {
                        settings.talkCombo = nil; settings.shortcuts = [:]; settings.clearedShortcuts = []; settings.talkMode = .holdOrTap
                    }
                }
            }

            ProSection()

            Section("Getting started") {
                HStack {
                    Text("Practice dictating in three short steps")
                    Spacer()
                    Button("Practice…") { NotificationCenter.default.post(name: .openPractice, object: nil) }
                }
                Toggle("Show advanced settings", isOn: $settings.showAdvanced)
                Text("Models, languages, sync, diagnostics and the Advanced tab. Everything works without them.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Engine", selection: $settings.provider) {
                    ForEach(Provider.allCases) { Text($0.label).tag($0) }
                }
                if !settings.provider.transcribesInCloud {
                    WhisperRow()
                    LabeledContent("Apple speech model") {
                        HStack {
                            Text(localStatus).foregroundStyle(.secondary)
                            if localStatus != "Ready" {
                                Button(downloading ? "Downloading…" : "Download") { downloadLocal() }.disabled(downloading)
                            }
                        }
                    }
                    Text("Free and private. Nothing leaves your Mac. Cloud Whisper is more accurate for names and accents.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if settings.provider == .custom {
                        fieldRow("Base URL", text: $settings.baseURL, prompt: Provider.custom.defaultBaseURL)
                    }
                    LabeledContent("API key") {
                        HStack(spacing: 8) {
                            SecureField("", text: $settings.apiKey, prompt: Text(keyPrompt))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .onChange(of: settings.apiKey) { _, _ in keyStatus = .idle }
                            Button(keyStatus == .testing ? "Testing…" : "Test") { testKey() }
                                .disabled(keyStatus == .testing || !settings.canUseCloud)
                        }
                    }
                    HStack {
                        keyStatusView
                        Spacer()
                        if let url = settings.provider.keyURL {
                            Link("Get a \(settings.provider.label) key →", destination: url)
                        }
                    }
                    if settings.showAdvanced { fieldRow("Speech model", text: $settings.transcriptionModel, prompt: settings.provider.defaultTranscriptionModel) }
                    Toggle("Fall back to on-device transcription when offline", isOn: $settings.offlineFallback)
                }
                Picker("Spoken language", selection: $settings.language) {
                    ForEach(Languages.spoken, id: \.code) { Text($0.name).tag($0.code) }
                    if !Languages.spoken.contains(where: { $0.code == settings.language }) { Text(settings.language).tag(settings.language) }
                }
                if settings.language.isEmpty { SpokenLanguagesRow() }
            }
            .onChange(of: settings.language) { _, language in
                LivePreview.prepare(language: language)
                refreshLocalStatus()
            }
            .onChange(of: settings.provider) { _, _ in
                keyStatus = .idle
                refreshLocalStatus()
            }

            Section("Cleanup") {
                Picker("Engine", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.cleanupMode == .apple || settings.cleanupMode == .auto {
                    LabeledContent("Apple model", value: AppleModel.status)
                    Text(settings.cleanupMode == .auto
                         ? "Uses the cloud LLM when you have a key (fastest, most accurate), otherwise Apple's on-device model, then basic rules."
                         : "Falls back to the cloud LLM, then basic rules, if the on-device model is unavailable or its output looks wrong.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if settings.showAdvanced, settings.cleanupMode != .rules, settings.cleanupMode != .off, settings.provider.isCloud {
                    fieldRow("Cleanup model (fast)", text: $settings.cleanupModel, prompt: settings.provider.defaultCleanupModel)
                    fieldRow("Smart model (translate, Command, Ask)", text: $settings.smartModel, prompt: settings.provider.defaultSmartModel)
                }
            }

            Section("Behavior") {
                Picker("Indicator", selection: $settings.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { Text($0.label).tag($0) }
                }
                if settings.indicatorStyle != .minimal {
                    Picker("Theme", selection: $settings.indicatorTheme) {
                        ForEach(IndicatorTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Show it", selection: $settings.indicatorPosition) {
                    ForEach(IndicatorPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sounds", selection: $settings.soundTheme) {
                    ForEach(SoundTheme.allCases) { Text($0.label).tag($0) }
                }
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("Automatic (\(AudioDevices.automatic(preferBuiltIn: settings.preferBuiltInMic)?.name ?? "none found"))").tag("")
                    Divider()
                    ForEach(devices) { device in
                        Text(device.name + (AudioDevices.kind(device) == .loopback ? " (system audio)" : "")).tag(device.uid)
                    }
                    if !settings.inputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == settings.inputDeviceUID }) {
                        Text("Not connected: using Automatic").tag(settings.inputDeviceUID)
                    }
                }
                .help("Automatic picks the best mic that's connected right now and follows you as devices come and go.")
                Picker(selection: $settings.playbackMode) {
                    ForEach(PlaybackMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When sound is playing on this Mac")
                        Text(settings.playbackMode == .hear
                             ? "Freshflo hears your Mac too, so a video or voice note playing aloud gets typed."
                             : "Mutes the speakers while you dictate so only your voice is typed; sound comes back when you stop. Headphones are never muted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.inputDeviceUID.isEmpty {
                    Toggle(isOn: $settings.preferBuiltInMic) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use the Mac's microphone instead of AirPods")
                            Text("Bluetooth headsets switch to call quality when their mic opens, which can cut off your first words and dull your music.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $settings.showCaptions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live captions while I speak")
                        Text("A card above the bar shows your words as you say them, and what Freshflo detects: a list or sentences, a question, a self-correction, filler words. Recognised on your Mac; nothing extra is sent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.showCaptions) { _, on in
                    guard on else { return }
                    Task { @MainActor in
                        // Captions fall back to Apple's older on-device recognizer, which needs Speech Recognition permission.
                        _ = await LocalSpeech.requestAuthorization()
                        LivePreview.prepare(language: settings.language)
                        refreshLocalStatus()
                        // macOS 26: fetch Apple's speech model for the language so captions are instant and fully on-device.
                        if #available(macOS 26.0, *), !LivePreview.isReady, !downloading { downloadLocal() }
                    }
                }
                if settings.showCaptions, localStatus != "Ready" {
                    LabeledContent("On-device speech model") {
                        HStack {
                            Text(localStatus).foregroundStyle(.secondary)
                            Button(downloading ? "Downloading…" : "Download") { downloadLocal() }.disabled(downloading)
                        }
                    }
                }
                LabeledContent("Turned off in") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(settings.blockedApps, id: \.self) { id in
                            HStack(spacing: 6) {
                                Text(appName(id)).foregroundStyle(.secondary)
                                Button { settings.blockedApps.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).help("Turn Freshflo back on here")
                            }
                        }
                        Button(settings.blockedApps.isEmpty ? "Choose apps…" : "Add app…", action: addBlockedApp)
                    }
                }
                Toggle("Use text around the cursor for smarter spacing and capitalization", isOn: $settings.useScreenContext)
                Toggle("Learn words I correct after dictating", isOn: $settings.autoLearn)
                Toggle("Monday recap: words and time saved last week", isOn: $settings.weeklyRecap)
                Toggle("Add a space after text when context isn't available", isOn: $settings.addTrailingSpace)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Permissions") {
                permissionRow(
                    "Microphone",
                    granted: permissions.microphone == .authorized,
                    action: {
                        if permissions.microphone == .notDetermined {
                            Permissions.requestMicrophone { _ in permissions.refresh() }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                )
                permissionRow(
                    "Accessibility (hotkey + paste)",
                    granted: permissions.accessibility,
                    action: {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.startPolling()
            devices = AudioDevices.inputs()
            refreshLocalStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in devices = AudioDevices.inputs() }
        .onDisappear { permissions.stopPolling() }
    }

    private var isFullyPrivate: Bool {
        settings.provider == .local && settings.cleanupMode != .api
    }

    private var keyPrompt: String {
        switch settings.provider {
        case .nebius: return "Paste key (nebius_…)"
        case .groq: return "Paste key (gsk_…)"
        case .openai: return "Paste key (sk-…)"
        case .custom: return "Optional"
        case .local: return "Not needed"
        }
    }

    @ViewBuilder private var keyStatusView: some View {
        switch keyStatus {
        case .idle:
            if settings.apiKey.isEmpty, settings.provider != .custom {
                Label("No key saved", systemImage: "key").foregroundStyle(.secondary)
            } else {
                Label("Key saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
            }
        case .testing:
            Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .ok:
            Label("Key works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func testKey() {
        keyStatus = .testing
        let endpoint = settings.endpoint
        Task { @MainActor in
            do {
                try await OpenAICompatible.verify(endpoint)
                keyStatus = .ok
            } catch {
                keyStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshLocalStatus() {
        guard !settings.provider.transcribesInCloud || settings.offlineFallback || settings.livePreview || settings.showCaptions else { return }
        let language = settings.language
        Task { @MainActor in localStatus = await LocalSpeech.status(language: language) }
    }

    private func downloadLocal() {
        downloading = true
        let language = settings.language
        Task { @MainActor in
            do {
                try await LocalSpeech.downloadModel(language: language)
            } catch {
                localStatus = error.localizedDescription
            }
            downloading = false
            LivePreview.prepare(language: language)
            refreshLocalStatus()
        }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addBlockedApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Turn Off Here"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.blockedApps.contains(id) { settings.blockedApps.append(id) }
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

/// Median timings and failures from the local diagnostics log (no dictated text is ever logged).
struct DiagnosticsSummary: View {
    @State private var summary = Diagnostics.summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Refresh") { summary = Diagnostics.summary() }
                Button("Show Log in Finder") { Diagnostics.revealLog() }
                Spacer()
                Text("Timings and errors only, never what you said.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onAppear { summary = Diagnostics.summary() }
    }
}
