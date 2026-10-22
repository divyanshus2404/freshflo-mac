import AppKit
import Combine
import Foundation

struct Meeting: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case recording, processing, ready, failed
    }

    var id: String
    var title: String
    var date: Date
    var duration: Double
    var status: Status
    var appName: String
    var notes: String
    var transcript: String
    var error: String?
    var onDevice: Bool?
    /// The transcript made readable: fillers, repeats and grammar fixed line by line, speakers and times kept.
    var cleanTranscript: String? = nil

    /// Everyone who speaks, in order of first appearance ("You", "Priya", "Speaker 2"…).
    var speakers: [String] {
        var seen: [String] = []
        for line in transcript.split(separator: "\n") {
            guard let close = line.firstIndex(of: "]"), let colon = line[close...].firstIndex(of: ":") else { continue }
            let name = line[line.index(after: close)..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}

/// Meeting notes on disk: ~/Library/Application Support/Freshflo/Meetings/<id>/meeting.json (+ audio while processing).
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [Meeting] = []
    let root: URL

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freshflo/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                  var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            // A meeting left "recording"/"processing" by a quit or crash can't resume on its own.
            let interrupted = meeting.status == .recording || meeting.status == .processing
            if interrupted, !ProcessingRegistry.active.contains(meeting.id), hasAudio(meeting.id) {
                meeting.status = .failed
                if meeting.error == nil { meeting.error = "Interrupted. Choose Retry to process the saved audio." }
            }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.date > $1.date }
    }

    func save(_ meeting: Meeting) {
        try? FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: folder(for: meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: folder(for: meeting.id))
        meetings.removeAll { $0.id == meeting.id }
    }

    func hasAudio(_ id: String) -> Bool {
        let f = folder(for: id)
        return FileManager.default.fileExists(atPath: f.appendingPathComponent("you.m4a").path)
            || FileManager.default.fileExists(atPath: f.appendingPathComponent("them.m4a").path)
    }

    func deleteAudio(_ id: String) {
        for name in ["you.m4a", "them.m4a"] {
            try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name))
        }
    }
}

enum ProcessingRegistry {
    static var active = Set<String>()
}

/// Turns the two recorded tracks into a speaker-labelled transcript and structured notes.
@MainActor
enum MeetingProcessor {
    static func process(_ meetingID: String, micHasAudio: Bool = true, systemHasAudio: Bool = true) async {
        let store = MeetingStore.shared
        guard var meeting = store.meetings.first(where: { $0.id == meetingID }) else { return }
        ProcessingRegistry.active.insert(meetingID)
        defer { ProcessingRegistry.active.remove(meetingID) }
        meeting.status = .processing
        meeting.error = nil
        store.save(meeting)

        let settings = AppSettings.shared
        let folder = store.folder(for: meetingID)
        do {
            var lines: [(start: Double, speaker: String, text: String)] = []
            let tracks = [("you.m4a", "You", micHasAudio), ("them.m4a", "Them", systemHasAudio)]
            var labelled: [String] = []
            for (file, speaker, hasAudio) in tracks where hasAudio {
                let url = folder.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let samples = try? AudioRecorder.load(url: url)
                // Whisper invents "Thank you." and the like on silence; drop those when the audio underneath really is silent.
                let segs = try await segments(url, settings: settings).filter { seg in
                    let text = Transcriber.stripHallucinations(seg.text)
                    guard !text.isEmpty else { return false }
                    guard let samples, Self.ghostPhrases.contains(SnippetExpander.normalize(text)) else { return true }
                    return Self.loudness(samples, from: seg.start, seconds: 2.5) > 0.004
                }
                var names = segs.map { _ in speaker }
                // Tell the other people apart by voice: "Speaker 1", "Speaker 2"… (named below when the call makes it clear).
                if speaker == "Them", segs.count >= 2, let samples,
                   let ids = Diarization.speakers(samples: samples, starts: segs.map(\.start)) {
                    names = ids.map { "Speaker \($0 + 1)" }
                    labelled = Array(Set(names)).sorted()
                }
                for (k, segment) in segs.enumerated() { lines.append((segment.start, names[k], segment.text)) }
            }
            lines = removeEcho(lines).sorted { $0.start < $1.start }
            guard !lines.isEmpty else { throw MeetingError.nothingHeard }

            meeting.transcript = format(lines)
            if !labelled.isEmpty {
                let names = await SpeakerNames.resolve(transcript: meeting.transcript, labels: labelled, settings: settings)
                if !names.isEmpty {
                    lines = lines.map { ($0.start, names[$0.speaker] ?? $0.speaker, $0.text) }
                    meeting.transcript = format(lines)
                }
            }
            meeting.onDevice = settings.provider == .local && !settings.canUseCloud
            store.save(meeting)

            let notes = try await Assistant.completeLong(
                instructions: notesInstructions(settings),
                text: meeting.transcript,
                chunkInstructions: "Extract the key points, decisions, action items (with owners) and open questions from this part of a meeting transcript. Be factual and concise."
            )
            meeting.notes = Cleanup.stripThinking(notes)
            if let firstLine = meeting.notes.components(separatedBy: "\n").first, firstLine.hasPrefix("# ") {
                meeting.title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                meeting.notes = meeting.notes.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            meeting.status = .ready
            store.save(meeting)
            // A readable copy of the transcript: grammar and fillers fixed, who said what kept.
            if settings.meetingCleanTranscript {
                meeting.cleanTranscript = await MeetingTools.cleanTranscript(meeting.transcript, settings: settings)
                store.save(meeting)
            }
            if !settings.keepMeetingAudio { store.deleteAudio(meetingID) }
        } catch {
            meeting.status = .failed
            meeting.error = error.localizedDescription
            store.save(meeting)
        }
    }

    nonisolated static let ghostPhrases: Set<String> = ["thank you", "thanks", "thank you very much", "thank you so much", "bye", "you", "okay", "so", "oh", "hmm"]

    /// RMS of a stretch of audio (16 kHz), for telling real speech from silence.
    nonisolated static func loudness(_ samples: [Float], from start: Double, seconds: Double) -> Float {
        let a = max(0, Int(start * 16_000)), b = min(samples.count, a + Int(seconds * 16_000))
        guard b > a else { return 0 }
        var sum: Float = 0
        for i in a..<b { sum += samples[i] * samples[i] }
        return sqrt(sum / Float(b - a))
    }

    private static func segments(_ url: URL, settings: AppSettings) async throws -> [Transcriber.Segment] {
        if !settings.provider.transcribesInCloud || !settings.canUseCloud {
            return try await LocalSpeech.transcribeSegments(file: url, language: settings.language, vocabulary: settings.dictionary)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 24 * 1024 * 1024 else { throw FileTranscriptionError.tooLarge }
        return try await Transcriber.transcribeSegments(data: data, filename: url.lastPathComponent,
                                                        endpoint: settings.endpoint, vocabulary: settings.dictionary)
    }

    /// Without headphones the mic also hears the other side; drop "You" lines that duplicate a nearby "Them" line.
    static func removeEcho(_ lines: [(start: Double, speaker: String, text: String)]) -> [(start: Double, speaker: String, text: String)] {
        let them = lines.filter { $0.speaker != "You" }
        guard !them.isEmpty else { return lines }
        return lines.filter { line in
            guard line.speaker == "You" else { return true }
            let words = Set(Cleanup.words(line.text))
            guard words.count >= 3 else { return true }
            return !them.contains { other in
                abs(other.start - line.start) < 8 && {
                    let otherWords = Set(Cleanup.words(other.text))
                    return Double(words.intersection(otherWords).count) / Double(words.count) > 0.6
                }()
            }
        }
    }

    private static func format(_ lines: [(start: Double, speaker: String, text: String)]) -> String {
        // Merge consecutive lines from the same speaker into one turn.
        var turns: [(start: Double, speaker: String, text: String)] = []
        for line in lines {
            if let last = turns.last, last.speaker == line.speaker, line.start - last.start < 60 {
                turns[turns.count - 1].text += " " + line.text
            } else {
                turns.append(line)
            }
        }
        return turns.map { turn in
            let s = Int(turn.start)
            return String(format: "[%02d:%02d] %@: %@", s / 60, s % 60, turn.speaker, turn.text)
        }.joined(separator: "\n")
    }

    private static func notesInstructions(_ settings: AppSettings) -> String {
        var text = """
        You write meeting notes from a transcript. "You" is the user. Everyone else is "Them", or labelled by name or as "Speaker 1", "Speaker 2"… when their voices could be told apart.
        Output Markdown in exactly this shape, omitting any section that would be empty:
        # <short, specific title>
        ## Summary
        2–4 sentences.
        ## Key points
        - …
        ## Decisions
        - …
        ## Who said what
        - **<speaker>**: <their main points and positions, one or two lines>
        ## Action items
        - [ ] <task> — <owner: You / a name / Speaker N / Them>, <due date if mentioned>
        ## Open questions
        - …
        Be factual: never invent names, numbers or commitments that aren't in the transcript.
        """
        if !settings.outputLanguage.isEmpty { text += "\nWrite the notes in \(settings.outputLanguage)." }
        if let regional = settings.regionalFormat.instruction { text += "\n" + regional }
        return text
    }
}

enum MeetingError: LocalizedError {
    case nothingHeard

    var errorDescription: String? { "No speech was recorded" }
}

/// Owns the in-progress recording and exposes state for the menu.
@MainActor
final class MeetingController: ObservableObject {
    static let shared = MeetingController()

    @Published private(set) var current: Meeting?
    private var recorder: MeetingRecorder?

    /// Live status for the recording card: both meters, and a warning when the call itself isn't being heard.
    struct Status: Equatable {
        var micLevel: Float = 0
        var callLevel: Float = 0
        var capturingCall = false
        var sources: [String] = []
        var warning: String?
    }
    @Published private(set) var status = Status()
    private var statusTimer: Timer?

    var isRecording: Bool { current != nil }

    func start() async -> String? {
        guard current == nil else { return nil }
        guard Permissions.microphone == .authorized else { return "Allow microphone access first" }
        let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { MeetingRecorder.meetingApps[$0] } }
        let app = running.first ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var meeting = Meeting(id: id, title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))", date: Date(),
                              duration: 0, status: .recording, appName: app, notes: "", transcript: "")
        MeetingStore.shared.save(meeting)
        let recorder = MeetingRecorder()
        do {
            let mic = AudioDevices.preferredUID(chosen: AppSettings.shared.inputDeviceUID, preferBuiltIn: AppSettings.shared.preferBuiltInMic)
            try await recorder.start(folder: MeetingStore.shared.folder(for: id), micDeviceUID: mic)
        } catch {
            meeting.status = .failed
            meeting.error = error.localizedDescription
            MeetingStore.shared.save(meeting)
            return error.localizedDescription
        }
        self.recorder = recorder
        current = meeting
        status = Status(capturingCall: recorder.capturesSystemAudio, sources: recorder.sources)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } }
        return recorder.capturesSystemAudio ? nil : "Recording your mic only. Allow Screen & System Audio Recording to capture the other side."
    }

    private func refreshStatus() {
        guard let recorder else { return }
        var next = status
        next.micLevel = recorder.micLevelNow
        next.callLevel = recorder.callLevelNow
        next.capturingCall = recorder.capturesSystemAudio
        let elapsed = Date().timeIntervalSince(recorder.startedAt)
        if !recorder.capturesSystemAudio {
            next.warning = "Only your side is being recorded. Allow Freshflo under Screen & System Audio Recording to capture the call."
        } else if elapsed > 30, recorder.callLastHeard == nil, recorder.micLastHeard != nil {
            next.warning = "Not hearing the call yet. Check the meeting app is playing through this Mac (not a phone), then keep going."
        } else {
            next.warning = nil
        }
        if next != status { status = next }
    }

    func stop() async {
        guard var meeting = current, let recorder else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        let tracks = await recorder.stop()
        meeting.duration = Date().timeIntervalSince(recorder.startedAt)
        MeetingStore.shared.save(meeting)
        current = nil
        self.recorder = nil
        await MeetingProcessor.process(meeting.id, micHasAudio: tracks.micHasAudio, systemHasAudio: tracks.systemHasAudio)
    }

    var elapsed: TimeInterval { recorder.map { Date().timeIntervalSince($0.startedAt) } ?? 0 }
}

/// What you can do with a meeting after the notes are written.
enum MeetingTools {
    enum Action: String, CaseIterable, Identifiable {
        case followUp, slack, actionItems, perPerson
        var id: String { rawValue }
        var label: String {
            switch self {
            case .followUp: return "Follow-up email"
            case .slack: return "Slack summary"
            case .actionItems: return "Action items"
            case .perPerson: return "Who said what"
            }
        }
        var icon: String {
            switch self {
            case .followUp: return "envelope"
            case .slack: return "number"
            case .actionItems: return "checklist"
            case .perPerson: return "person.2"
            }
        }
        var instruction: String {
            switch self {
            case .followUp:
                return "Write a short, friendly follow-up email from the user (\"You\") to the other participants: thank them, recap the decisions, list action items with owners and dates, and mention any open questions. Greeting line, short paragraphs, sign-off without a name."
            case .slack:
                return "Write a Slack message summarising the meeting for people who weren't there: one opening line, then 3–6 short bullets (decisions first, then action items with owners). No headings."
            case .actionItems:
                return "List every action item as a checklist: \"- [ ] task — owner, due date\". Only items that were actually agreed. If there are none, say so."
            case .perPerson:
                return "For each person who spoke, give their name in bold, then 2–4 bullets with what they said, asked for or committed to. Keep each person's own positions; don't merge them."
            }
        }
    }

    /// Runs one of the follow-up actions on a meeting's notes and transcript.
    static func run(_ action: Action, meeting: Meeting, settings: AppSettings) async throws -> String {
        let instructions = action.instruction + "\nUse only what's in the notes and transcript. Never invent names, numbers, dates or commitments. Output only the result."
        let prompt = "Meeting: \(meeting.title) (\(meeting.date.formatted(date: .abbreviated, time: .shortened)))\n\nNotes:\n\(meeting.notes)\n\nTranscript:\n\(meeting.transcript.prefix(14_000))"
        if settings.canUseCloud {
            return Cleanup.stripThinking(try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: 0.2))
        }
        if AppleModel.isAvailable { return Cleanup.stripThinking(try await AppleModel.respond(instructions: instructions, prompt: prompt)) }
        throw KnowledgeError.noModel
    }

    /// "[00:12] Priya: um so I I think we should, like, ship it friday" → "[00:12] Priya: I think we should ship it on Friday."
    /// Batches lines through the cleanup model; a batch that comes back malformed keeps its original lines. Then the
    /// deterministic pass (stutters, repeats, swear words, spoken-English grammar) runs on every line.
    static func cleanTranscript(_ transcript: String, settings: AppSettings) async -> String {
        let lines = transcript.components(separatedBy: "\n")
        var batches: [[String]] = [[]]
        var size = 0
        for line in lines {
            if size + line.count > 2_500, !(batches.last ?? []).isEmpty { batches.append([]); size = 0 }
            batches[batches.count - 1].append(line)
            size += line.count
        }
        let instructions = """
        You clean up a meeting transcript. Each input line looks like "[mm:ss] Speaker: words".
        For every line, keep the "[mm:ss] Speaker:" prefix exactly, and rewrite only the words: remove filler words (um, uh, like, you know), stutters and accidental repeats, apply self-corrections, and fix grammar and punctuation so it reads as clear written English. Keep the meaning, the speaker's own words and any Hindi or other non-English words.
        Output exactly the same number of lines, in the same order, one output line per input line, and nothing else.
        """
        var out: [String] = []
        for batch in batches where !batch.isEmpty {
            var cleaned: [String]?
            if settings.canUseCloud || AppleModel.isAvailable {
                let prompt = batch.joined(separator: "\n")
                let reply = settings.canUseCloud
                    ? try? await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint)
                    : try? await AppleModel.respond(instructions: instructions, prompt: prompt)
                if let reply {
                    let got = Cleanup.stripThinking(reply).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    // Same count and every prefix intact, or this batch keeps its original lines.
                    if got.count == batch.count, zip(got, batch).allSatisfy({ prefix($0) == prefix($1) }) { cleaned = got }
                }
            }
            out += (cleaned ?? batch).map { polish($0, settings: settings) }
        }
        return out.joined(separator: "\n")
    }

    static func prefix(_ line: String) -> String {
        guard let close = line.firstIndex(of: "]"), let colon = line[close...].firstIndex(of: ":") else { return "" }
        return String(line[...colon])
    }

    private static func polish(_ line: String, settings: AppSettings) -> String {
        let p = prefix(line)
        guard !p.isEmpty else { return line }
        let words = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        let options = TextPolish.Options(profanity: settings.profanity, dictionary: settings.dictionary, grammar: true, tone: .formal, lists: false)
        return p + " " + TextPolish.apply(Cleanup.rules(words, tone: .formal), options)
    }

    /// Renames a speaker everywhere: transcript, clean transcript and notes. "Speaker 2" → "Priya".
    static func rename(_ meeting: Meeting, from old: String, to new: String) -> Meeting {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return meeting }
        var m = meeting
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: old) + #"\b"#
        func swap(_ text: String) -> String {
            text.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        m.transcript = swap(m.transcript)
        m.cleanTranscript = m.cleanTranscript.map(swap)
        if old != "You" { m.notes = swap(m.notes) }
        return m
    }
}
