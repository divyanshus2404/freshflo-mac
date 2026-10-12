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
    @State private var clean = true
    @State private var copied = false
    @State private var working: String?
    @State private var result: (title: String, text: String)?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var error: String?

    private var transcriptText: String { clean ? (meeting.cleanTranscript ?? meeting.transcript) : meeting.transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text("\(meeting.date.formatted(date: .complete, time: .shortened))\(meeting.appName.isEmpty ? "" : " · \(meeting.appName)")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if meeting.status == .ready {
                    Picker("", selection: $tab) {
                        Text("Notes").tag(0)
                        Text("Transcript").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
            }

            switch meeting.status {
            case .recording:
                LiveRecordingCard()
                Spacer()
            case .processing:
                HStack { ProgressView().controlSize(.small); Text("Transcribing, telling voices apart and writing notes…").foregroundStyle(.secondary) }
                Spacer()
            case .failed:
                Label(meeting.error ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if MeetingStore.shared.hasAudio(meeting.id) {
                    Button("Retry") { Task { await MeetingProcessor.process(meeting.id) } }
                }
                Spacer()
            case .ready:
                speakersRow
                if tab == 1 {
                    HStack(spacing: 10) {
                        if meeting.cleanTranscript != nil {
                            Picker("", selection: $clean) {
                                Text("Clean").tag(true)
                                Text("As spoken").tag(false)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                            Text(clean ? "Grammar and fillers fixed; who said what kept." : "Exactly as transcribed.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button { cleanUp() } label: { Label("Make it grammatically correct", systemImage: "wand.and.stars") }
                                .disabled(working != nil)
                        }
                    }
                }
                ScrollView {
                    if tab == 0 {
                        MarkdownText(text: meeting.notes).padding(.trailing, 8)
                    } else {
                        Text(transcriptText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let working { HStack { ProgressView().controlSize(.small); Text(working).foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Button(role: .destructive) {
                    MeetingStore.shared.delete(meeting)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                if meeting.status == .ready {
                    Menu {
                        ForEach(MeetingTools.Action.allCases) { action in
                            Button { run(action) } label: { Label(action.label, systemImage: action.icon) }
                        }
                    } label: {
                        Label("Create", systemImage: "sparkles")
                    }
                    .fixedSize()
                    .disabled(working != nil)
                    Button("Export Markdown…") { export() }
                    Button(copied ? "Copied" : "Copy \(tab == 0 ? "Notes" : "Transcript")") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tab == 0 ? "# \(meeting.title)\n\n\(meeting.notes)" : transcriptText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .sheet(isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            if let result { ResultSheet(title: result.title, text: result.text) { self.result = nil } }
        }
    }

    /// Everyone who spoke; click a name to rename it everywhere (Speaker 2 → Priya).
    @ViewBuilder private var speakersRow: some View {
        let speakers = meeting.speakers
        if !speakers.isEmpty {
            HStack(spacing: 6) {
                Text("Speakers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(speakers, id: \.self) { name in
                    Button {
                        renaming = name
                        newName = name.hasPrefix("Speaker ") ? "" : name
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: name == "You" ? "person.fill" : "person")
                            Text(name)
                            if name != "You" { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(name == "You")
                    .popover(isPresented: Binding(get: { renaming == name }, set: { if !$0 { renaming = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Who is \(name)?").font(.headline)
                            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { applyRename(name) }
                            HStack { Spacer(); Button("Rename") { applyRename(name) }.keyboardShortcut(.defaultAction) }
                        }
                        .padding(14)
                    }
                }
                Spacer()
            }
        }
    }

    private func applyRename(_ old: String) {
        let updated = MeetingTools.rename(meeting, from: old, to: newName)
        MeetingStore.shared.save(updated)
        renaming = nil
    }

    private func cleanUp() {
        working = "Making the transcript grammatically correct…"
        error = nil
        let snapshot = meeting
        Task { @MainActor in
            var m = snapshot
            m.cleanTranscript = await MeetingTools.cleanTranscript(snapshot.transcript, settings: AppSettings.shared)
            MeetingStore.shared.save(m)
            clean = true
            working = nil
        }
    }

    private func run(_ action: MeetingTools.Action) {
        working = "Writing \(action.label.lowercased())…"
        error = nil
        let snapshot = meeting
        Task { @MainActor in
            do { result = (action.label, try await MeetingTools.run(action, meeting: snapshot, settings: AppSettings.shared)) }
            catch { self.error = error.localizedDescription }
            working = nil
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = "# \(meeting.title)\n\n_\(meeting.date.formatted(date: .complete, time: .shortened))_\n\n\(meeting.notes)\n\n## Transcript\n\n\(meeting.cleanTranscript ?? meeting.transcript)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The live card while a meeting records: one meter for you, one for the call, and a clear warning if the call isn't heard.
private struct LiveRecordingCard: View {
    @ObservedObject private var controller = MeetingController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Recording").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = Int(controller.elapsed)
                    Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button { NotificationCenter.default.post(name: .toggleMeeting, object: nil) } label: {
                    Label("Stop and write notes", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
            meter("You", level: controller.status.micLevel, icon: "mic.fill")
            meter(controller.status.sources.first.map { "The call (\($0))" } ?? "The call", level: controller.status.capturingCall ? controller.status.callLevel : 0,
                  icon: "speaker.wave.2.fill", off: !controller.status.capturingCall)
            if let warning = controller.status.warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !controller.status.capturingCall {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
            }
            Text("Your mic and the call are recorded as separate tracks; other voices are told apart afterwards. Music and video apps are left out. Nothing joins the call.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private func meter(_ label: String, level: Float, icon: String, off: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(off ? Color.secondary : Color.green)
            Text(label).frame(width: 170, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(off ? Color.secondary.opacity(0.3) : Color.green)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, Double(level) * 8))))
                        .animation(.linear(duration: 0.12), value: level)
                }
            }
            .frame(height: 8)
            Text(off ? "Not recording" : level > 0.004 ? "Hearing" : "Quiet").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
    }
}

/// A follow-up email, Slack summary or action list, ready to copy.
private struct ResultSheet: View {
    let title: String
    let text: String
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Close", action: close)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
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
