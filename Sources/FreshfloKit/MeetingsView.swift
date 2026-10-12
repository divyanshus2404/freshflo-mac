import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var controller = MeetingController.shared
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !store.meetings.isEmpty {
                    Label("Ask your meetings", systemImage: "sparkles")
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .tag("ask")
                }
                ForEach(store.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title).font(.body.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                            if meeting.duration > 0 { Text("· \(Int(meeting.duration / 60)) min") }
                            statusBadge(meeting)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(meeting.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if store.meetings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.and.mic").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No meetings yet").font(.headline)
                        Text("Start meeting notes from the menu bar during any call.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        } detail: {
            if selection == "ask" {
                AskMeetingsView(selection: $selection)
            } else if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting)
            } else {
                Text("Select a meeting").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            store.reload()
            if selection == nil { selection = store.meetings.first?.id }
        }
        .onChange(of: store.meetings.first?.id) { _, newest in
            if selection == nil || controller.isRecording { selection = newest }
        }
    }

    @ViewBuilder private func statusBadge(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recording: Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case .processing: Label("Writing notes…", systemImage: "hourglass")
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .ready:
            if meeting.onDevice == true { Label("On-device", systemImage: "lock.fill").foregroundStyle(.green) }
        }
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @State private var tab = 0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text("\(meeting.date.formatted(date: .complete, time: .shortened))\(meeting.appName.isEmpty ? "" : " · \(meeting.appName)")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    Text("Notes").tag(0)
                    Text("Transcript").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }

            switch meeting.status {
            case .recording:
                Label("Recording… stop from the menu bar to write notes.", systemImage: "record.circle").foregroundStyle(.red)
                Spacer()
            case .processing:
                HStack { ProgressView().controlSize(.small); Text("Transcribing and writing notes…").foregroundStyle(.secondary) }
                Spacer()
            case .failed:
                Label(meeting.error ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if MeetingStore.shared.hasAudio(meeting.id) {
                    Button("Retry") { Task { await MeetingProcessor.process(meeting.id) } }
                }
                Spacer()
            case .ready:
                ScrollView {
                    if tab == 0 {
                        MarkdownText(text: meeting.notes).padding(.trailing, 8)
                    } else {
                        Text(meeting.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack {
                Button(role: .destructive) {
                    MeetingStore.shared.delete(meeting)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                if meeting.status == .ready {
                    Button("Export Markdown…") { export() }
                    Button(copied ? "Copied" : "Copy \(tab == 0 ? "Notes" : "Transcript")") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tab == 0 ? "# \(meeting.title)\n\n\(meeting.notes)" : meeting.transcript, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = "# \(meeting.title)\n\n_\(meeting.date.formatted(date: .complete, time: .shortened))_\n\n\(meeting.notes)\n\n## Transcript\n\n\(meeting.transcript)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}


/// "What did we decide about pricing?" across every meeting, answered from your notes with the meetings it came from.
private struct AskMeetingsView: View {
    @Binding var selection: String?
    @ObservedObject private var store = MeetingStore.shared
    @State private var question = ""
    @State private var answer: Knowledge.Answer?
    @State private var asking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let suggestions = ["What did we decide this week?", "What are my action items?", "What did the client ask for?", "Summarise my last meeting"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask your meetings").font(.system(size: 26, design: .serif))
            Text("Answers come only from your notes, and say which meeting each point came from.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("e.g. What did we decide about pricing?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(ask)
                Button(asking ? "Asking…" : "Ask", action: ask)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(asking || question.trimmingCharacters(in: .whitespaces).count < 3)
            }
            if answer == nil, !asking {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { question = s; ask() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if asking { ProgressView().controlSize(.small) }
            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(answer.text).textSelection(.enabled).font(.body).fixedSize(horizontal: false, vertical: true)
                        if !answer.sources.isEmpty {
                            Divider()
                            Text("From").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(answer.sources) { m in
                                Button { selection = m.id } label: {
                                    Label(Knowledge.label(m), systemImage: "doc.text")
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, !asking else { return }
        asking = true; error = nil; answer = nil
        Task { @MainActor in
            do { answer = try await Knowledge.ask(q, meetings: store.meetings, settings: AppSettings.shared) }
            catch { self.error = error.localizedDescription }
            asking = false
        }
    }
}
