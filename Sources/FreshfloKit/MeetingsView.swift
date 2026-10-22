import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var controller = MeetingController.shared
    @State private var selection: String?
    /// A conversation to open "Chat with your meetings" with (the `--render-ui` screenshots).
    private let initialTurns: [Knowledge.Turn]

    init(initialSelection: String? = nil, initialTurns: [Knowledge.Turn] = []) {
        _selection = State(initialValue: initialSelection)
        self.initialTurns = initialTurns
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !store.meetings.isEmpty {
                    Label("Chat with your meetings", systemImage: "sparkles")
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .tag("ask")
                    Label("Open commitments", systemImage: "checklist")
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .tag("commitments")
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
                        Button("Try it with sample meetings") {
                            Task { @MainActor in
                                _ = await DemoMeetings.seed()
                                selection = "ask"
                            }
                        }
                        .buttonStyle(.link)
                    }
                    .padding()
                }
            }
        } detail: {
            if selection == "ask" {
                AskMeetingsView(selection: $selection, initialTurns: initialTurns)
            } else if selection == "commitments" {
                CommitmentsView(selection: $selection)
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
                    if meeting.status == .ready, let writtenBy = meeting.writtenBy {
                        ModelBadge(credit: writtenBy).padding(.top, 4)
                    }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(off ? "not recording" : level > 0.004 ? "hearing sound" : "quiet")")
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
    var initialTurns: [Knowledge.Turn] = []
    @ObservedObject private var store = MeetingStore.shared
    @State private var question = ""
    @State private var turns: [Knowledge.Turn] = []
    @State private var asking = false
    @FocusState private var focused: Bool

    private let suggestions = ["What did we decide this week?", "What are my action items?", "What did the client ask for?", "Summarise my last meeting"]

    private var canSend: Bool { !asking && question.trimmingCharacters(in: .whitespaces).count >= 3 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .onAppear {
            focused = true
            if turns.isEmpty { turns = initialTurns }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chat with your meetings").font(.system(size: 22, design: .serif))
                Spacer()
                if !turns.isEmpty {
                    Button { turns = [] } label: { Label("New chat", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderless)
                }
            }
            Text("Answers come only from your notes, cite the meeting they came from, and remember the conversation so far.")
                .font(.callout).foregroundStyle(.secondary)
            if let credit = ModelCredit.configured(.shared) {
                ModelBadge(credit: credit).padding(.top, 2)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if turns.isEmpty, !asking { emptyState }
                    ForEach(turns) { turn in
                        bubble(role: "You", text: turn.question, mine: true)
                        if !turn.answer.isEmpty {
                            bubble(role: "Freshflo", text: turn.answer, mine: false, failed: turn.failed, sources: turn.sources,
                                   model: turn.model, seconds: turn.seconds)
                                .id(turn.id)
                        }
                    }
                    if asking, turns.last?.answer.isEmpty ?? true {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your notes…").foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .id("bottom")
            }
            .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: asking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: turns.last?.answer) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask anything about your meetings").font(.headline)
            ForEach(suggestions, id: \.self) { s in
                Button { question = s; send() } label: {
                    Label(s, systemImage: "sparkles").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .frame(maxWidth: 460)
    }

    @ViewBuilder private func bubble(role: String, text: String, mine: Bool, failed: Bool = false, sources: [Meeting] = [],
                                     model: String? = nil, seconds: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "…" : text)
                .textSelection(.enabled).font(.body)
                .foregroundStyle(failed ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !sources.isEmpty {
                WrapChips(sources: sources) { selection = $0 }
            }
            if let model {
                ModelBadge(credit: model, extra: seconds.map { String(format: "%.1f s", $0) })
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mine ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up… e.g. and who owns that?", text: $question)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, !asking else { return }
        question = ""
        asking = true
        let history = turns
        let turn = Knowledge.Turn(question: q, answer: "", sources: [])
        turns.append(turn)
        let start = Date()
        Task { @MainActor in
            do {
                // The reply streams into its bubble as it is written; sources and the model badge arrive with the last token.
                let answer = try await Knowledge.converse(history: history, question: q, meetings: store.meetings, settings: AppSettings.shared) { partial in
                    update(turn.id) { $0.answer = partial }
                }
                update(turn.id) {
                    $0.answer = answer.text
                    $0.sources = answer.sources
                    $0.model = answer.model
                    $0.seconds = Date().timeIntervalSince(start)
                }
            } catch {
                update(turn.id) {
                    $0.answer = error.localizedDescription
                    $0.failed = true
                }
            }
            asking = false
            focused = true
        }
    }

    private func update(_ id: UUID, _ change: (inout Knowledge.Turn) -> Void) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[i])
    }
}

/// Source meeting chips that wrap onto multiple lines.
private struct WrapChips: View {
    let sources: [Meeting]
    let open: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(sources) { m in
                Button { open(m.id) } label: {
                    Label(Knowledge.label(m), systemImage: "doc.text").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
