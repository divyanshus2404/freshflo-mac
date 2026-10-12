import AppKit
import SwiftUI

/// Scratchpad: a place to think out loud. Notes you dictate here, plus anything you dictate with no text field
/// to type into (the desktop, or an app that blocks pasting), so a thought is never lost.
struct ScratchNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var updated = Date()
    var text = ""

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.isEmpty ? "New note" : String(first.prefix(60))
    }
}

final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()
    @Published private(set) var notes: [ScratchNote] = []
    private let url: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Freshflo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("Scratchpad.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([ScratchNote].self, from: data) { notes = saved }
    }

    @discardableResult
    func newNote(_ text: String = "") -> ScratchNote {
        let note = ScratchNote(text: text)
        notes.insert(note, at: 0)
        persist()
        return note
    }

    /// Dictation with nowhere to go: added to a note from the last few minutes, or a new one.
    func capture(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let i = notes.indices.first, Date().timeIntervalSince(notes[i].updated) < 300, notes[i].text.count < 4_000 {
            notes[i].text += (notes[i].text.isEmpty ? "" : "\n\n") + clean
            notes[i].updated = Date()
            persist()
        } else {
            newNote(clean)
        }
    }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        persist(debounced: true)
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
    }

    private func persist(debounced: Bool = false) {
        saveWork?.cancel()
        let snapshot = notes, url = url
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(snapshot).write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (debounced ? 0.6 : 0), execute: work)
    }
}

struct ScratchpadView: View {
    @ObservedObject private var store = ScratchpadStore.shared
    @State private var selection: UUID?
    @State private var draft = ""
    @State private var copied = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.body.weight(.medium)).lineLimit(1)
                        Text(note.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(note.id)
                    .contextMenu { Button("Delete", role: .destructive) { remove(note.id) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button { selection = store.newNote().id } label: { Label("New Note", systemImage: "square.and.pencil") }
                        .keyboardShortcut("n")
                }
            }
        } detail: {
            if let id = selection, store.notes.contains(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $draft)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .padding(20)
                        .onChange(of: draft) { _, text in store.update(id, text: text) }
                    Divider()
                    HStack {
                        Text("Click in the note, hold your talk key and speak.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        Button("Delete", role: .destructive) { remove(id) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .onAppear { draft = store.notes.first { $0.id == id }?.text ?? "" }
                .onChange(of: selection) { _, new in draft = store.notes.first { $0.id == new }?.text ?? "" }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Think out loud").font(.system(size: 22, design: .serif))
                    Text("Start a note and dictate into it. Anything you dictate with no text field in front of you lands here too, so nothing gets lost.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    Button("New Note") { selection = store.newNote().id }.buttonStyle(.borderedProminent).padding(.top, 4)
                }
                .padding()
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { if selection == nil { selection = store.notes.first?.id } }
        // A dictation that just landed here: show it.
        .onChange(of: store.notes.first?.updated) { _, _ in
            if let first = store.notes.first, first.id == selection { draft = first.text } else { selection = store.notes.first?.id }
        }
    }

    private func remove(_ id: UUID) {
        store.delete(id)
        if selection == id { selection = store.notes.first?.id }
    }
}
