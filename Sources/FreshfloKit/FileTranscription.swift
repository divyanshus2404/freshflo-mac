import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileTranscriptionError: LocalizedError {
    case tooLarge
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "That file is too large to upload (max ~25 MB after compression)"
        case .unreadable(let ext): return "Can't read .\(ext) files on-device; switch to a cloud engine for this one"
        }
    }
}

/// Transcribes audio files and voice notes (e.g. WhatsApp .opus) into clean, paragraphed text.
@MainActor
enum FileTranscription {
    private static let uploadLimit = 24 * 1024 * 1024
    private static var windows: [NSWindow] = []

    static func pickAndTranscribe() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe an audio file"
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav] + ["opus", "ogg", "webm", "flac", "m4a"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url)
    }

    static func transcribe(_ url: URL) {
        let model = FileResultModel(filename: url.lastPathComponent)
        show(model)
        Task { @MainActor in
            do {
                let settings = AppSettings.shared
                model.status = "Transcribing…"
                let raw = try await rawTranscript(url, settings: settings)
                model.raw = raw
                model.status = "Polishing…"
                var context = FocusContext()
                context.appName = "a document"
                let polished = await Pipeline.polish(raw: raw, context: context, settings: settings, longForm: true)
                model.text = polished.text
                model.status = nil
                HistoryStore.shared.add(HistoryItem(
                    date: Date(), appName: "🎙 \(url.lastPathComponent)", bundleID: "", raw: raw, text: polished.text,
                    tone: settings.defaultTone, duration: 0, cleanup: polished.engine, mode: .dictation,
                    transcriber: settings.provider == .local ? LocalSpeech.engineName(language: settings.language) : settings.endpoint.transcriptionModel
                ))
            } catch {
                model.status = nil
                model.error = error.localizedDescription
            }
        }
    }

    private static func rawTranscript(_ url: URL, settings: AppSettings) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if settings.provider == .local {
            guard let samples = try? AudioRecorder.load(url: url) else { throw FileTranscriptionError.unreadable(ext) }
            return try await LocalSpeech.transcribe(samples, language: settings.language, vocabulary: settings.dictionary)
        }
        let data = try Data(contentsOf: url)
        if Transcriber.directUploadExtensions.contains(ext), data.count <= uploadLimit {
            return try await Transcriber.transcribeFile(data: data, filename: url.lastPathComponent, endpoint: settings.endpoint, vocabulary: settings.dictionary)
        }
        // Too big or an unusual format: decode and re-encode as compact 16 kHz AAC.
        guard let samples = try? AudioRecorder.load(url: url) else { throw FileTranscriptionError.unreadable(ext) }
        let aac = try AudioRecorder.m4a(from: samples)
        guard aac.count <= uploadLimit else { throw FileTranscriptionError.tooLarge }
        return try await Transcriber.transcribeFile(data: aac, filename: "audio.m4a", endpoint: settings.endpoint, vocabulary: settings.dictionary)
    }

    private static func show(_ model: FileResultModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.filename
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileResultView(model: model))
        window.center()
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

final class FileResultModel: ObservableObject {
    let filename: String
    @Published var status: String? = "Preparing…"
    @Published var text = ""
    @Published var raw = ""
    @Published var error: String?

    init(filename: String) {
        self.filename = filename
    }
}

private struct FileResultView: View {
    @ObservedObject var model: FileResultModel
    @State private var showRaw = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                Spacer()
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Spacer()
            } else {
                ScrollView {
                    Text(showRaw ? model.raw : model.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                HStack {
                    Toggle("Show original transcript", isOn: $showRaw).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(model.text.split(whereSeparator: \.isWhitespace).count) words").foregroundStyle(.secondary).font(.callout)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(showRaw ? model.raw : model.text, forType: .string)
                        copied = true
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }
}
