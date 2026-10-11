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
            if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
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
