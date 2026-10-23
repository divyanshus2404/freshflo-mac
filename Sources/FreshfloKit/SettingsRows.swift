import AppKit
import ServiceManagement
import SwiftUI

struct ConnectRow: View {
    let name: String
    let url: URL
    let note: String
    @State private var connected = false
    @State private var error: String?

    var body: some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Disconnect") { act { try MCPServer.disconnect(url) } }
                } else {
                    Button("Connect") { act { try MCPServer.connect(url) } }
                }
            }
        }
        .help(error ?? note)
        .onAppear { connected = MCPServer.isConnected(url) }
    }

    private func act(_ change: () throws -> Void) {
        do { try change(); error = nil } catch { self.error = "Couldn't update \(url.lastPathComponent): \(error.localizedDescription)" }
        connected = MCPServer.isConnected(url)
    }
}


struct ShareSyncRow: View {
    @ObservedObject private var sync = ShareSync.shared
    @State private var entering = false
    @State private var typed = ""
    @State private var error: String?
    @State private var revealed = false

    var body: some View {
        if sync.isOn {
            LabeledContent("Your code") {
                HStack {
                    Text(revealed ? SyncCrypto.pretty(sync.code) : "••••-••••-••••-" + String(sync.code.suffix(4)))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SyncCrypto.pretty(sync.code), forType: .string)
                    }
                }
            }
            LabeledContent("Status") {
                HStack {
                    if let e = sync.lastError { Text(e).foregroundStyle(.red).lineLimit(2) }
                    else if sync.busy { Text("Syncing…").foregroundStyle(.secondary) }
                    else if let last = sync.lastSynced { Text("Synced \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary) }
                    else { Text("Waiting…").foregroundStyle(.secondary) }
                    Button("Sync now") { sync.syncNow() }
                }
            }
            HStack {
                Text("On another device, open Freshflo's settings, choose “I have a code” and type this code.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Turn off") {
                    Button("Turn off on this Mac") { sync.turnOff(erase: false) }
                    Button("Turn off and delete the synced copy", role: .destructive) { sync.turnOff(erase: true) }
                }
                .fixedSize()
            }
        } else if entering {
            LabeledContent("Code from your other device") {
                HStack {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $typed)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 220)
                        .onSubmit(connect)
                    Button("Connect", action: connect).disabled(typed.isEmpty)
                    Button("Cancel") { entering = false; typed = ""; error = nil }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } else {
            HStack {
                Button("Turn on sync") { sync.turnOn(); revealed = true }
                Button("I have a code") { entering = true }
            }
        }
    }

    private func connect() {
        error = sync.turnOn(code: typed)
        if error == nil { entering = false; typed = "" }
    }
}


struct SyncRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var sync = FolderSync.shared

    private var mode: String {
        if settings.syncFolder.isEmpty { return "off" }
        return settings.syncFolder == FolderSync.iCloudFolder.path ? "icloud" : "folder"
    }

    var body: some View {
        Picker("Sync dictionary, snippets and styles", selection: Binding(get: { mode }, set: choose)) {
            Text("Off").tag("off")
            Text("iCloud Drive").tag("icloud").disabled(!FolderSync.iCloudAvailable)
            Text(mode == "folder" ? URL(fileURLWithPath: settings.syncFolder).lastPathComponent : "Shared folder…").tag("folder")
        }
        if mode != "off" {
            LabeledContent("Status") {
                HStack {
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.red).lineLimit(2)
                    } else if let last = sync.lastSynced {
                        Text("Synced \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    } else {
                        Text("Waiting…").foregroundStyle(.secondary)
                    }
                    Button("Sync now") { sync.syncNow() }
                    Button("Show") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.syncFolder) }
                }
            }
        }
    }

    private func choose(_ value: String) {
        switch value {
        case "icloud": settings.syncFolder = FolderSync.iCloudFolder.path
        case "folder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Share Here"
            panel.message = "Choose a folder you share with your team (Dropbox, Google Drive, OneDrive…)."
            if panel.runModal() == .OK, let url = panel.url { settings.syncFolder = url.path }
        default: settings.syncFolder = ""
        }
    }
}


/// The built-in engine's best mode: Whisper on this Mac. One download, then free, offline and private.
struct WhisperRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var progress: Double?
    @State private var error: String?
    @State private var ready = OnDeviceWhisper.isDownloaded

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $settings.useOnDeviceWhisper) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper on this Mac (best free accuracy)")
                    Text("The same model as the cloud engines, running on your Mac's Neural Engine: no key, works offline, nothing leaves your Mac. One-time download, \(OnDeviceWhisper.sizeLabel).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.useOnDeviceWhisper {
                if ready {
                    Label("Downloaded and ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if let progress {
                    ProgressView(value: progress) { Text("Downloading… \(Int(progress * 100))%").font(.caption) }
                } else {
                    Button("Download Whisper (\(OnDeviceWhisper.sizeLabel))") { download() }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private func download() {
        progress = 0; error = nil
        Task { @MainActor in
            do {
                try await OnDeviceWhisper.download { p in Task { @MainActor in progress = p } }
                ready = OnDeviceWhisper.isDownloaded
            } catch { self.error = error.localizedDescription }
            progress = nil
        }
    }
}


/// "Languages I speak": detection only considers these, and a clip heard as another language is transcribed again in yours.
struct SpokenLanguagesRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        LabeledContent {
            Menu(summary) {
                ForEach(Languages.spoken.filter { !$0.code.isEmpty }, id: \.code) { lang in
                    Button { toggle(lang.code) } label: {
                        if settings.spokenLanguages.contains(lang.code) { Label(lang.name, systemImage: "checkmark") } else { Text(lang.name) }
                    }
                }
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Languages I speak")
                Text("Freshflo detects which one you're using each time. Pick only yours, so a short clip is never mistaken for another language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let names = settings.spokenLanguages.compactMap { code in Languages.spoken.first { $0.code == code }?.name }
        return names.isEmpty ? "Any language" : names.joined(separator: ", ")
    }

    private func toggle(_ code: String) {
        if let i = settings.spokenLanguages.firstIndex(of: code) { settings.spokenLanguages.remove(at: i) } else { settings.spokenLanguages.append(code) }
    }
}
