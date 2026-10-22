import AppKit
import SwiftUI

// MARK: - What changed (History)

/// Explains a dictation: the words Freshflo removed or added, and the kinds of changes it made.
enum ChangeExplainer {
    enum Kind: Equatable { case same, removed, added }
    struct Token: Equatable { var text: String; var kind: Kind }

    /// Word-level diff (longest common subsequence), compared ignoring case and punctuation.
    static func diff(_ raw: String, _ text: String) -> [Token] {
        let a = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let ka = a.map(key), kb = b.map(key)
        guard a.count * b.count <= 250_000 else { return b.map { Token(text: $0, kind: .same) } }
        var l = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                l[i][j] = ka[i] == kb[j] && !ka[i].isEmpty ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var out: [Token] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j], !ka[i].isEmpty { out.append(Token(text: b[j], kind: .same)); i += 1; j += 1 }
            else if j < b.count, i == a.count || l[i][j + 1] >= l[i + 1][j] { out.append(Token(text: b[j], kind: .added)); j += 1 }
            else { out.append(Token(text: a[i], kind: .removed)); i += 1 }
        }
        return out
    }

    /// Plain-language list of what happened, e.g. ["Removed 3 fillers (um, uh)", "Made a numbered list"].
    static func summary(raw: String, text: String) -> [String] {
        let tokens = diff(raw, text)
        var notes: [String] = []
        let removed = tokens.filter { $0.kind == .removed }.map { $0.text.lowercased().filter(\.isLetter) }
        let fill = removed.filter { ["um", "uh", "erm", "er", "ah", "hmm", "uhm"].contains($0) }
        if !fill.isEmpty { notes.append("Removed \(fill.count) filler\(fill.count == 1 ? "" : "s") (\(Array(Set(fill)).sorted().joined(separator: ", ")))") }
        let rawLower = raw.lowercased()
        if ["no wait", "i mean", "actually no", "scratch that", "sorry i mean"].contains(where: rawLower.contains) {
            notes.append("Applied your correction")
        }
        let words = raw.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if zip(words, words.dropFirst()).contains(where: { $0 == $1 }) { notes.append("Removed repeated words") }
        if text.range(of: #"(?m)^\s*(\d+\.|[-•])\s"#, options: .regularExpression) != nil,
           raw.range(of: #"(?m)^\s*(\d+\.|[-•])\s"#, options: .regularExpression) == nil { notes.append("Made a list") }
        if text.contains("\n\n"), !raw.contains("\n\n") { notes.append("Laid it out in paragraphs") }
        let punct = { (s: String) in s.filter { ".,?!;:".contains($0) }.count }
        if punct(text) > punct(raw) { notes.append("Added punctuation") }
        let otherRemoved = removed.count - fill.count
        let added = tokens.filter { $0.kind == .added }.count
        if otherRemoved > 0 || added > 0, notes.count < 4 { notes.append("Reworded \(max(otherRemoved, added)) word\(max(otherRemoved, added) == 1 ? "" : "s") for grammar and clarity") }
        return notes.isEmpty ? ["Kept exactly what you said"] : notes
    }
}

struct ChangeView: View {
    let raw: String
    let text: String

    private static func piece(_ t: ChangeExplainer.Token) -> Text {
        let word: Text = Text(t.text)
        switch t.kind {
        case .same: return word
        case .removed: return word.strikethrough().foregroundColor(Color.red.opacity(0.75))
        case .added: return word.foregroundColor(Color.green)
        }
    }

    private static func render(_ tokens: [ChangeExplainer.Token]) -> Text {
        var out: Text = Text("")
        for t in tokens {
            let p: Text = piece(t)
            out = out + p
            out = out + Text(" ")
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ChangeExplainer.summary(raw: raw, text: text), id: \.self) { note in
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Self.render(ChangeExplainer.diff(raw, text))
            .font(.callout)
            .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Copy what I said") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(raw, forType: .string)
                }
                Button("Paste what I said") {
                    let r = raw
                    NSApp.hide(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TextInserter.insert(r) }
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - One searchable list of everything (settings search and ⌘K)

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle = ""
    var keywords = ""
    var symbol = "gearshape"
    let run: () -> Void

    func score(_ q: String) -> Int {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 1 }
        let t = title.lowercased(), all = (title + " " + subtitle + " " + keywords).lowercased()
        if t.hasPrefix(q) { return 100 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 80 }
        if all.contains(q) { return 50 }
        // Every word of the query appears somewhere.
        let parts = q.split(separator: " ")
        if parts.count > 1, parts.allSatisfy({ all.contains($0) }) { return 30 }
        return 0
    }

    static func search(_ q: String, in list: [PaletteCommand]) -> [PaletteCommand] {
        list.map { ($0, $0.score(q)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Every setting, by the words people use for it, and the tab it lives on.
enum SettingsIndex {
    struct Entry { let title: String; let keywords: String; let tab: SettingsTab; let advanced: Bool }
    static let entries: [Entry] = [
        .init(title: "Talk key", keywords: "hotkey shortcut fn globe option key combination", tab: .general, advanced: false),
        .init(title: "How the talk key works", keywords: "hold tap toggle double-tap hands-free mode", tab: .general, advanced: false),
        .init(title: "Hands-free: finish when I stop talking", keywords: "auto stop pause silence end", tab: .general, advanced: false),
        .init(title: "More shortcuts", keywords: "cancel escape paste last meeting scratchpad keyboard", tab: .general, advanced: false),
        .init(title: "Command mode", keywords: "control rewrite selected text", tab: .general, advanced: false),
        .init(title: "Ask mode", keywords: "shift question reminder calendar email", tab: .general, advanced: false),
        .init(title: "Engine", keywords: "transcription groq openai whisper provider speech", tab: .general, advanced: false),
        .init(title: "API key", keywords: "groq key keychain cloud", tab: .general, advanced: false),
        .init(title: "On-device Whisper", keywords: "offline private local model download", tab: .general, advanced: false),
        .init(title: "Speech and cleanup models", keywords: "model name endpoint llm smart model", tab: .general, advanced: true),
        .init(title: "Microphone", keywords: "mic input airpods device automatic built-in", tab: .general, advanced: false),
        .init(title: "Sounds", keywords: "chime audio feedback beep", tab: .appearance, advanced: false),
        .init(title: "Theme", keywords: "colour color fluid custom appearance", tab: .appearance, advanced: false),
        .init(title: "Make your own theme", keywords: "colour color custom import export share", tab: .appearance, advanced: false),
        .init(title: "Dark mode", keywords: "light dark appearance windows", tab: .appearance, advanced: false),
        .init(title: "Indicator style and size", keywords: "bar pill glass orb island position size", tab: .appearance, advanced: false),
        .init(title: "Live captions", keywords: "captions subtitles words while speaking", tab: .appearance, advanced: false),
        .init(title: "Writing style per app", keywords: "tone formal casual style slack email", tab: .tone, advanced: false),
        .init(title: "Grammar", keywords: "fix grammar correct", tab: .tone, advanced: false),
        .init(title: "Smart lists and emails", keywords: "bullet numbered list email format", tab: .tone, advanced: false),
        .init(title: "Swear words", keywords: "profanity mask clean", tab: .tone, advanced: false),
        .init(title: "Dictionary", keywords: "words names spelling vocabulary learn contacts", tab: .dictionary, advanced: false),
        .init(title: "Snippets", keywords: "text expansion shortcut phrase signature", tab: .snippets, advanced: false),
        .init(title: "History", keywords: "past dictations search what changed original", tab: .history, advanced: false),
        .init(title: "Meeting notes", keywords: "meetings speakers who said what calls zoom", tab: .meetings, advanced: false),
        .init(title: "Languages I speak", keywords: "language hindi hinglish detect translate", tab: .advanced, advanced: true),
        .init(title: "Write in another language", keywords: "translate output language", tab: .advanced, advanced: true),
        .init(title: "App language", keywords: "interface hindi localization", tab: .advanced, advanced: true),
        .init(title: "Sync", keywords: "icloud folder team share dictionary", tab: .advanced, advanced: true),
        .init(title: "Use in Claude and Cursor", keywords: "mcp claude cursor connect", tab: .general, advanced: false),
        .init(title: "Agents and research", keywords: "tavily hermes agent research next step nemoclaw web search", tab: .meetings, advanced: false),
        .init(title: "Diagnostics", keywords: "logs debug problem report", tab: .advanced, advanced: true),
        .init(title: "Turn off in certain apps", keywords: "block disable app", tab: .advanced, advanced: true),
    ]
}

// MARK: - Command palette (⌘K)

@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()
    private var panel: NSPanel?
    var commands: () -> [PaletteCommand] = { [] }

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    func show() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: PaletteView(all: commands(), close: { [weak self] in self?.close() }))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 280, y: f.midY + 40))
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil); panel = nil }
    func windowDidResignKey(_ notification: Notification) { close() }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
}

private struct PaletteView: View {
    let all: [PaletteCommand]
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [PaletteCommand] { Array(PaletteCommand.search(query, in: all).prefix(30)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("What do you want to do?", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { run(selected) }
                    .onChange(of: query) { _, _ in selected = 0 }
                Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                            Button { run(i) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: c.symbol).frame(width: 20).foregroundStyle(i == selected ? .white : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.title).foregroundStyle(i == selected ? .white : .primary)
                                        if !c.subtitle.isEmpty {
                                            Text(c.subtitle).font(.caption).foregroundStyle(i == selected ? .white.opacity(0.8) : .secondary)
                                        }
                                    }
                                    Spacer()
                                    if i == selected { Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(i == selected ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                        if results.isEmpty {
                            Text("Nothing matches “\(query)”").foregroundStyle(.secondary).padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { _, s in proxy.scrollTo(s) }
            }
        }
        .frame(width: 560, height: 380)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func run(_ i: Int) {
        guard results.indices.contains(i) else { return }
        let c = results[i]
        close()
        DispatchQueue.main.async { c.run() }
    }
}

// MARK: - Settings search

struct SettingsSearchResults: View {
    let query: String
    let open: (SettingsSearchResults.Hit) -> Void
    struct Hit: Identifiable { let id: String; let title: String; let tab: SettingsTab; let advanced: Bool }

    static func hits(_ q: String) -> [Hit] {
        let cmds = SettingsIndex.entries.map { e in PaletteCommand(id: e.title, title: e.title, subtitle: tabName(e.tab), keywords: e.keywords, run: {}) }
        let found = PaletteCommand.search(q, in: cmds).map(\.id)
        return found.compactMap { id in SettingsIndex.entries.first { $0.title == id }.map { Hit(id: $0.title, title: $0.title, tab: $0.tab, advanced: $0.advanced) } }
    }

    static func tabName(_ t: SettingsTab) -> String {
        switch t {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .tone: return "Style"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .history: return "History"
        case .meetings: return "Meetings"
        case .advanced: return "Advanced"
        }
    }

    var body: some View {
        let hits = Self.hits(query)
        List {
            if hits.isEmpty { Text("No settings match “\(query)”").foregroundStyle(.secondary) }
            ForEach(hits) { h in
                Button { open(h) } label: {
                    HStack {
                        Text(h.title)
                        Spacer()
                        Text(Self.tabName(h.tab)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Practice

/// Three short exercises after setup, each checked live, so the first real dictation isn't a guess.
struct PracticeView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var step = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    struct Exercise { let title: String; let say: String; let tip: String; let check: (String) -> Bool }

    static let exercises: [Exercise] = [
        .init(title: "A normal sentence", say: "“Hey, can you send me the deck before tomorrow's call?”",
              tip: "Freshflo adds the capital letter and the question mark for you.",
              check: { t in t.split(separator: " ").count >= 5 && [".", "?", "!"].contains(where: t.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix) }),
        .init(title: "Change your mind", say: "“Um, let's meet on Tuesday, no wait, Wednesday.”",
              tip: "Ums vanish, and “no wait” keeps only what you meant.",
              check: { t in let l = t.lowercased(); return l.contains("wednesday") && !l.contains("tuesday") && !l.contains("um ") && !l.hasPrefix("um") }),
        .init(title: "A list", say: "“My packing list: first my charger, second my passport, third sunscreen.”",
              tip: "Say “first… second… third…” and you get a numbered list.",
              check: { t in t.contains("1.") && t.contains("2.") }),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ForEach(0..<Self.exercises.count, id: \.self) { i in
                    Capsule().fill(i < step ? Color.green : i == step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 5)
                }
            }
            if step < Self.exercises.count {
                let ex = Self.exercises[step]
                Text("Step \(step + 1) of \(Self.exercises.count): \(ex.title)").font(.headline)
                Text("Hold \(settings.talkKeyLabel) and say:").foregroundStyle(.secondary)
                Text(ex.say).font(.title3).fontDesign(.serif)
                TextEditor(text: $text)
                    .font(.body).frame(height: 110).focused($focused)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ex.check(text) ? Color.green : Color.secondary.opacity(0.3)))
                if ex.check(text) {
                    Label("Nice. \(ex.tip)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if !text.isEmpty {
                    Text("Not quite: try saying it again. (Click the box first, then hold the key.)").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Skip") { advance() }
                    Spacer()
                    Button("Next") { advance() }.keyboardShortcut(.defaultAction).disabled(!ex.check(text))
                }
            } else {
                Text("You're ready 🎉").font(.title2.weight(.semibold))
                Text("Hold \(settings.talkKeyLabel) in any app and talk. Press ⌃⌥K (or use the menu bar) to find anything in Freshflo.")
                    .foregroundStyle(.secondary)
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { focused = true }
    }

    private func advance() { step += 1; text = ""; focused = true }
}

// MARK: - Problems with one-click fixes

struct Problem: Identifiable {
    let id: String
    let title: String
    let fix: String
    let action: () -> Void
}
