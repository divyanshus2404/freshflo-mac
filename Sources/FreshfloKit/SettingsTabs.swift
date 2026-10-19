import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Style

/// Meeting notes and the AI apps that can read them.
struct MeetingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Meeting notes") {
                Text("Start from the menu bar during any call (Zoom, Meet, Teams, Slack…). Your mic and the call audio are recorded as separate tracks, so the transcript knows who said what. You get a summary, decisions and action items.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Keep the audio after notes are written", isOn: $settings.keepMeetingAudio)
                Toggle("Also make a grammatically clean copy of the transcript", isOn: $settings.meetingCleanTranscript)
                Toggle("Offer to take notes when a call starts (Zoom, Teams, Meet…)", isOn: $settings.offerMeetingNotes)
                HStack {
                    Text("Capturing the other side needs “Screen & System Audio Recording” permission.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            Section {
                ConnectRow(name: "Claude Desktop", url: MCPServer.claudeConfigURL, note: "Restart Claude after connecting.")
                ConnectRow(name: "Cursor", url: MCPServer.cursorConfigURL, note: "Cursor picks it up in Settings → MCP.")
                LabeledContent("Claude Code, other apps") {
                    HStack {
                        Button("Copy command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("claude mcp add freshflo -- \"\(MCPServer.executablePath)\" --mcp", forType: .string)
                        }
                        Button("Copy JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MCPServer.configSnippet, forType: .string)
                        }
                    }
                }
                Toggle(isOn: $settings.mcpShareHistory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also let them search what I dictate")
                        Text("Off: they can only read meeting notes. Nothing is uploaded by Freshflo; the AI app reads it only when it needs to.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Use Freshflo in Claude and Cursor")
            } footer: {
                Text("Ask Claude things like \u{201C}What did we decide in Tuesday's sync?\u{201D} or \u{201C}Draft a follow-up from my last meeting.\u{201D} It searches your Freshflo notes on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}

/// Sync, diagnostics and feedback: things most people set once or never.
struct AdvancedTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                SyncRow()
            } header: {
                Text("Sync and share")
            } footer: {
                Text("Your dictionary, snippets and app styles are kept in one file. iCloud Drive keeps your Macs in step; a shared Dropbox, Google Drive or OneDrive folder shares them with your team. New items from anyone are added everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Language & region") {
                Picker("App language", selection: Binding(
                    get: { (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { ["en", "hi"].contains(String($0.prefix(2))) && UserDefaults.standard.object(forKey: "freshflo.appLanguage") != nil ? String($0.prefix(2)) : nil } ?? "" },
                    set: { value in
                        if value.isEmpty {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                            UserDefaults.standard.removeObject(forKey: "freshflo.appLanguage")
                        } else {
                            UserDefaults.standard.set([value], forKey: "AppleLanguages")
                            UserDefaults.standard.set(value, forKey: "freshflo.appLanguage")
                        }
                        languageChanged = true
                    })) {
                    Text("Same as macOS").tag("")
                    Text("English").tag("en")
                    Text("हिन्दी").tag("hi")
                }
                if languageChanged {
                    HStack {
                        Text("Restart Freshflo to switch the language.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") {
                            let config = NSWorkspace.OpenConfiguration()
                            config.createsNewApplicationInstance = true
                            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                                DispatchQueue.main.async { NSApp.terminate(nil) }
                            }
                        }
                    }
                }
            }

            Section("Diagnostics") {
                DiagnosticsSummary()
                Toggle(isOn: $settings.shareUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share anonymous usage counts and crash reports")
                        Text("Once a day: how many dictations, words and failures, and which engine. Never your words or app names.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Send Feedback…") { (NSApp.delegate as? AppDelegate)?.openFeedback() }
            }

        }
        .formStyle(.grouped)
    }
}

struct ToneTab: View {
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
                Toggle(isOn: $settings.autoPromptMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt mode in AI tools")
                        Text("In Cursor, Claude, ChatGPT, AI chat sites and terminals running Claude Code or Codex, write a clear, structured prompt.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.smartLists) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart lists")
                        Text("Say \u{201C}first… second… third…\u{201D} for a numbered list, or \u{201C}bullet point…\u{201D} for bullets. Everything else stays as sentences.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.emailFormatting) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Email formatting")
                        Text("In Mail, Outlook, Gmail and other mail apps: greeting on its own line, short paragraphs, sign-off at the end.").font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                    Picker("", selection: $settings.outputLanguage) {
                        ForEach(Languages.written, id: \.self) { Text($0.isEmpty ? "Same as spoken" : $0).tag($0) }
                        if !Languages.written.contains(settings.outputLanguage) { Text(settings.outputLanguage).tag(settings.outputLanguage) }
                    }
                    .labelsHidden()
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

struct AppIconView: View {
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

struct DictionaryTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newWord = ""
    @State private var importing = false
    @State private var importNote: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.knownNames.isEmpty ? "Spell the people you know correctly" : "\(settings.knownNames.count) names from Contacts and Calendar")
                        Text("Freshflo reads names from your Contacts and the people in your recent meetings, and uses them as spelling hints. They stay on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !settings.knownNames.isEmpty { Button("Clear") { settings.knownNames = [] } }
                    Button(importing ? "Reading…" : settings.knownNames.isEmpty ? "Import names" : "Refresh") { importNames() }.disabled(importing)
                }
            } header: { Text("Names") }

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

    private func importNames() {
        importing = true
        Task { @MainActor in
            let result = await NameBook.harvest()
            if !result.names.isEmpty { settings.knownNames = result.names }
            importNote = result.problem ?? "Added \(result.names.count) names."
            importing = false
        }
    }

    private func add() {
        for word in newWord.components(separatedBy: ",") { _ = settings.learn(word) }
        newWord = ""
    }
}

/// Wrapping horizontal layout for word chips.
struct FlowLayout: Layout {
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

struct SnippetsTab: View {
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

struct HistoryTab: View {
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

struct StatsRow: View {
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

struct HistoryRow: View {
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
                DisclosureGroup(item.mode == .command ? "Spoken instruction" : "What changed", isExpanded: $showRaw) {
                    if item.mode == .command {
                        Text(item.raw).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        ChangeView(raw: item.raw, text: item.text).padding(.top, 4)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}


/// One AI app that can read Freshflo through MCP: connect or disconnect it by editing its config file.
