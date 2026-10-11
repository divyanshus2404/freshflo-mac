import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, tone, dictionary, snippets, history
}

final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ToneTab().tabItem { Label("Style", systemImage: "textformat") }.tag(SettingsTab.tone)
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(SettingsTab.dictionary)
            SnippetsTab().tabItem { Label("Snippets", systemImage: "text.badge.plus") }.tag(SettingsTab.snippets)
            HistoryTab().tabItem { Label("History", systemImage: "clock") }.tag(SettingsTab.history)
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
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

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $tryText)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                    if tryText.isEmpty {
                        Text("Click here, hold \(settings.hotkey.shortLabel) and say something…")
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
                Picker("Dictation key", selection: $settings.hotkey) {
                    ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
                }
                Text("Hold to talk and release to insert. Tap once for hands-free, then tap again to finish. Press Esc to cancel.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Command mode: hold \(settings.hotkey.shortLabel) + Control", isOn: $settings.commandModeEnabled)
                Toggle("Ask mode: hold \(settings.hotkey.shortLabel) + Shift", isOn: $settings.askModeEnabled)
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

            Section("Transcription") {
                Picker("Engine", selection: $settings.provider) {
                    ForEach(Provider.allCases) { Text($0.label).tag($0) }
                }
                if settings.provider == .local {
                    LabeledContent("On-device model") {
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
                    fieldRow("Speech model", text: $settings.transcriptionModel, prompt: settings.provider.defaultTranscriptionModel)
                    Toggle("Fall back to on-device transcription when offline", isOn: $settings.offlineFallback)
                }
                fieldRow("Spoken language", text: $settings.language, prompt: "auto (or en, hi, es…)")
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
                if settings.cleanupMode != .rules, settings.cleanupMode != .off, settings.provider.isCloud {
                    fieldRow("Cleanup model (fast)", text: $settings.cleanupModel, prompt: settings.provider.defaultCleanupModel)
                    fieldRow("Smart model (translate, Command, Ask)", text: $settings.smartModel, prompt: settings.provider.defaultSmartModel)
                }
            }

            Section("Behavior") {
                Picker("Indicator", selection: $settings.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { Text($0.label).tag($0) }
                }
                if settings.indicatorStyle == .halo {
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
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("Show my words live while I speak (on-device, private)", isOn: $settings.livePreview)
                if settings.livePreview, localStatus != "Ready" {
                    LabeledContent("On-device speech model") {
                        HStack {
                            Text(localStatus).foregroundStyle(.secondary)
                            Button(downloading ? "Downloading…" : "Download") { downloadLocal() }.disabled(downloading)
                        }
                    }
                }
                Toggle("Use text around the cursor for smarter spacing and capitalization", isOn: $settings.useScreenContext)
                Toggle("Learn words I correct after dictating", isOn: $settings.autoLearn)
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

            Section("Meeting notes") {
                Text("Start from the menu bar during any call (Zoom, Meet, Teams, Slack…). Your mic and the call audio are recorded as separate tracks, so the transcript knows who said what. You get a summary, decisions and action items.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Keep the audio after notes are written", isOn: $settings.keepMeetingAudio)
                HStack {
                    Text("Capturing the other side needs “Screen & System Audio Recording” permission.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            Section("Diagnostics") {
                DiagnosticsSummary()
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
        .onDisappear { permissions.stopPolling() }
    }

    private var isFullyPrivate: Bool {
        settings.provider == .local && settings.cleanupMode != .api
    }

    private var keyPrompt: String {
        switch settings.provider {
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
        guard settings.provider == .local || settings.offlineFallback || settings.livePreview else { return }
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
private struct DiagnosticsSummary: View {
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

// MARK: - Style

private struct ToneTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Default tone", selection: $settings.defaultTone) {
                    ForEach(Tone.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.defaultTone.example).font(.callout).foregroundStyle(.secondary)
            } footer: {
                Text("Tone is applied by the cleanup engine based on the app you're dictating into.")
            }

            Section("Per-app tone") {
                if settings.toneRules.isEmpty {
                    Text("No app rules yet.").foregroundStyle(.secondary)
                }
                ForEach($settings.toneRules) { $rule in
                    HStack {
                        AppIconView(bundleID: rule.bundleID)
                        Text(rule.appName)
                        Spacer()
                        Picker("", selection: $rule.tone) {
                            ForEach(Tone.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Button {
                            settings.toneRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add app…") {
                    ForEach(availableApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            settings.toneRules.append(AppToneRule(
                                bundleID: app.bundleIdentifier ?? "",
                                appName: app.localizedName ?? "",
                                tone: settings.defaultTone
                            ))
                        }
                    }
                }
                .fixedSize()
            }

            Section {
                Toggle(isOn: $settings.fixGrammar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fix grammar")
                        Text("Correct tense, agreement, articles and misheard words, not just punctuation.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker(selection: $settings.profanity) {
                    ForEach(ProfanityMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Swear words")
                        Text(settings.profanity.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Clean and correct")
            } footer: {
                Text("Repeated words and stutters (\u{201C}I I think\u{201D}, \u{201C}th- the\u{201D}) are always removed, and names close to ones in your Dictionary are spelled your way.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Write in") {
                    TextField("", text: $settings.outputLanguage, prompt: Text("Same as spoken"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Picker("Regional formatting", selection: $settings.regionalFormat) {
                    ForEach(RegionalFormat.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Language & region")
            } footer: {
                Text("Speak in any language and get text in another: e.g. speak Hindi or Hinglish, write “English”; or write “Hindi (Devanagari)” or “Hinglish in Roman script”.")
            }

            Section {
                TextField("", text: $settings.customInstructions, prompt: Text("e.g. Use British spelling. Never use em dashes. Write numbers as digits."), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Applied to every cleanup and command, on top of the tone.")
            }
        }
        .formStyle(.grouped)
    }

    private var availableApps: [NSRunningApplication] {
        let existing = Set(settings.toneRules.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !existing.contains($0.bundleIdentifier!) }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct AppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app").frame(width: 18, height: 18)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("", text: $newWord, prompt: Text("Add a name, brand or term (e.g. Divyanshu, Kubernetes)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.dictionary.isEmpty {
                    Text("No words yet. Freshflo also learns words you correct after dictating.").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.dictionary, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                Button {
                                    settings.dictionary.removeAll { $0 == word }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Dictionary")
            } footer: {
                Text("Words here are passed to the speech model and the cleanup model, so they're spelled exactly as written.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        for word in newWord.components(separatedBy: ",") { _ = settings.learn(word) }
        newWord = ""
    }
}

/// Wrapping horizontal layout for word chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                y += rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Snippets

private struct SnippetsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach($settings.snippets) { $snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("", text: $snippet.trigger, prompt: Text("Say… (e.g. my calendar link)"))
                                .textFieldStyle(.roundedBorder)
                            Button {
                                settings.snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("", text: $snippet.expansion, prompt: Text("…to insert"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...6)
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    settings.snippets.append(Snippet(trigger: "", expansion: ""))
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say a trigger phrase on its own, or inside a sentence, and Freshflo inserts the saved text instead. Variables: {date}, {time}, {day}, {tomorrow}, {clipboard}.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        guard !query.isEmpty else { return history.items }
        return history.items.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            StatsRow(items: history.items)
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                Button("Clear All") { confirmClear = true }.disabled(history.items.isEmpty)
            }
            if filtered.isEmpty {
                Spacer()
                Text(history.items.isEmpty ? "Your dictations will appear here." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { item in
                    HistoryRow(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        }
    }
}

private struct StatsRow: View {
    let items: [HistoryItem]
    private static let typingWPM = 40.0

    var body: some View {
        let words = items.reduce(0) { $0 + $1.wordCount }
        let speakingMinutes = items.reduce(0) { $0 + $1.duration } / 60
        let wpm = speakingMinutes > 0 ? Double(words) / speakingMinutes : 0
        let saved = max(0, Double(words) / Self.typingWPM - speakingMinutes)
        HStack(spacing: 10) {
            stat("\(words.formatted())", "words dictated")
            stat(wpm > 0 ? "\(Int(wpm))" : "–", "words / min")
            stat(saved >= 60 ? String(format: "%.1f h", saved / 60) : "\(Int(saved)) min", "saved vs typing")
            stat("\(items.count)", "dictations")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    @State private var showRaw = false

    static let redoOptions: [(String, String)] = [
        ("More formal", "Rewrite this more formally."),
        ("More casual", "Rewrite this more casually, like a friendly message."),
        ("Shorter", "Make this shorter and tighter without losing meaning."),
        ("Fix grammar only", "Fix grammar, spelling and punctuation only; change nothing else."),
        ("Bullet points", "Turn this into concise bullet points."),
        ("Translate to English", "Translate this into natural English."),
        ("Translate to Hindi", "Translate this into natural Hindi (Devanagari)."),
    ]

    @MainActor
    private func redo(_ instruction: String) {
        let card = AnswerCard.shared
        card.show(icon: "wand.and.stars", title: instruction, subtitle: String(item.text.prefix(80)))
        Task { @MainActor in
            do {
                var context = FocusContext()
                context.appName = item.appName
                let result = try await Pipeline.command(instruction: instruction, selection: item.text, context: context, settings: AppSettings.shared)
                card.update(body: result, actions: card.textActions(result))
            } catch {
                card.update(body: "⚠︎ " + error.localizedDescription, actions: [])
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AppIconView(bundleID: item.bundleID)
                Text(item.appName.isEmpty ? "Unknown app" : item.appName).font(.caption.weight(.semibold))
                if item.mode == .command {
                    Text("Command").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                }
                Text("· \(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.tone.label) · \(item.cleanup)\(item.latencyMs.map { String(format: " · %.2f s", Double($0) / 1000) } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                if item.transcriber != nil {
                    Label(item.stayedOnDevice ? "Stayed on this Mac" : "Cloud", systemImage: item.stayedOnDevice ? "lock.fill" : "cloud")
                        .font(.caption2)
                        .foregroundStyle(item.stayedOnDevice ? .green : .secondary)
                        .help(item.stayedOnDevice ? "Audio and text never left this Mac" : "Sent to \(item.transcriber ?? "cloud") for transcription")
                }
                Spacer()
                Menu {
                    ForEach(Self.redoOptions, id: \.0) { option in
                        Button(option.0) { redo(option.1) }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Redo this dictation…")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Button {
                    HistoryStore.shared.delete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            Text(item.text).textSelection(.enabled)
            if item.raw != item.text {
                DisclosureGroup(item.mode == .command ? "Spoken instruction" : "Original transcript", isExpanded: $showRaw) {
                    Text(item.raw).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
