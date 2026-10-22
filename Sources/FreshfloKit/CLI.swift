import AppKit
import SwiftUI
import Foundation

/// Headless test hook: runs the real pipeline on an audio file and prints each stage.
///   Freshflo --transcribe speech.aiff [--local] [--app com.apple.mail] [--before "text before cursor"]
///   Freshflo --command "make this formal" [--selection "hey whats up"]
public enum CLI {
    public static var isRequested: Bool {
        ["--transcribe", "--command", "--models", "--file", "--preview", "--ask", "--meeting", "--render-pill", "--stream-test", "--render-onboarding", "--render-onboarding-steps", "--benchmark", "--check-update", "--grammar-eval", "--ask-meetings", "--render-stats", "--mic-test", "--polish-batch", "--voice-sense", "--render-appearance", "--render-styles", "--diarize", "--mic-info", "--whisper-local", "--seed-demo", "--remove-demo", "--commitments", "--next-step", "--research", "--commitments-eval"].contains(where: CommandLine.arguments.contains)
    }

    /// Shows the real floating indicator inside a proper app run loop with synthetic speech (performance checks).
    public static var isDemoRequested: Bool { CommandLine.arguments.contains("--demo-pill") }
    /// Launched by Claude Desktop, Claude Code or Cursor as an MCP server.
    public static var isMCPRequested: Bool { CommandLine.arguments.contains("--mcp") }
    public static func runMCP() -> Never { MCPServer.run() }
    /// Serves MCP over HTTP for sandboxed agents (NemoClaw / OpenShell): `--mcp-http [--port 8765] [--bind 127.0.0.1]`.
    public static var isMCPHTTPRequested: Bool { CommandLine.arguments.contains("--mcp-http") }
    public static func runMCPHTTP() -> Never {
        MCPHTTP.run(port: UInt16(value("--port") ?? "") ?? 8765, bind: value("--bind") ?? "127.0.0.1",
                    token: ProcessInfo.processInfo.environment["FRESHFLO_MCP_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    @MainActor
    public static func runDemo() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        nonisolated(unsafe) let pill = PillController()
        let start = Date()
        nonisolated(unsafe) var stage = 0
        Timer.scheduledTimer(withTimeInterval: 0.043, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start)
                if stage == 0 { pill.showRecording(mode: .dictation, locked: false); stage = 1 }
                if t < 11 {
                    let syllable = Float(max(0, sin(t * 9)) * (0.6 + 0.4 * sin(t * 1.3)))
                    pill.model.push(syllable)
                    pill.model.pushBands(SIMD3(syllable * 0.9, syllable * 0.7, Float(max(0, sin(t * 23))) * syllable))
                    // Real recognizers update ~4×/s with whole words.
                    let phrase = "so I was thinking we could meet on Wednesday and send the deck".split(separator: " ")
                    if t > 2 {
                        let words = min(phrase.count, Int((t - 2) * 4))
                        let text = phrase.prefix(words).joined(separator: " ")
                        if text != pill.model.liveText { pill.model.liveText = text }
                    }
                } else if stage == 1 {
                    pill.showProcessing("Polishing…"); stage = 2
                } else if stage == 2, t > 12 {
                    pill.success("12 words"); stage = 3
                } else if stage == 3, t > 13.5 {
                    timer.invalidate()
                    print("demo done")
                    exit(0)
                }
            }
        }
        app.run()
        exit(0)
    }

    public static func run() -> Never {
        Task { @MainActor in
            do {
                try await execute()
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    private static func execute() async throws {
        let settings = AppSettings.shared
        // Temporary overrides for experiments; restored before exit so saved settings don't change.
        let savedLanguage = settings.outputLanguage, savedRegion = settings.regionalFormat, savedSpoken = settings.language
        defer {
            settings.outputLanguage = savedLanguage
            settings.regionalFormat = savedRegion
            settings.language = savedSpoken
        }
        if let spoken = value("--lang") { settings.language = spoken }
        let savedCleanupModel = settings.cleanupModel
        defer { settings.cleanupModel = savedCleanupModel }
        if let model = value("--cleanup-model") { settings.cleanupModel = model }
        let savedSmartModel = settings.smartModel
        defer { settings.smartModel = savedSmartModel }
        if let model = value("--smart-model") { settings.smartModel = model }
        // CI and scripted runs: `--provider nebius` with the key in FRESHFLO_API_KEY (or NEBIUS_API_KEY), for this run only.
        let savedProvider = settings.provider
        // What the overridden provider had before this run: its saved key and models, put back on exit.
        var overridden: (provider: Provider, key: String, cleanup: String, smart: String)?
        if let raw = value("--provider"), let provider = Provider(rawValue: raw) {
            let env = ProcessInfo.processInfo.environment
            let key = (env["FRESHFLO_API_KEY"] ?? env["NEBIUS_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let storedKey = Keychain.get(provider.rawValue)
            settings.provider = provider
            overridden = (provider, storedKey, settings.cleanupModel, settings.smartModel)
            if !key.isEmpty { settings.apiKey = key }
            if let model = value("--cleanup-model") { settings.cleanupModel = model }
            if let model = value("--smart-model") { settings.smartModel = model }
            print("provider: \(provider.label) · fast \(settings.cleanupModel) · smart \(settings.smartModel) · key \(settings.apiKey.isEmpty ? "missing" : "set")")
        }
        defer {
            if let o = overridden {
                if settings.provider == o.provider {
                    settings.apiKey = o.key
                    settings.cleanupModel = o.cleanup
                    settings.smartModel = o.smart
                }
                settings.provider = savedProvider
            }
        }
        if let lang = value("--write-in") { settings.outputLanguage = lang }
        if let region = value("--region").flatMap(RegionalFormat.init(rawValue:)) { settings.regionalFormat = region }

        if let path = value("--stream-test") {
            // Replays a file in real time with the same pause-cut rule as live dictation, then times release → text.
            let all = try AudioRecorder.load(url: URL(fileURLWithPath: path))
            let rate = 16_000
            var cut = 0
            var tasks: [Task<String, Error>] = []
            let endpoint = settings.endpoint
            for end in stride(from: rate / 4, through: all.count, by: rate / 4) {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard end - cut > rate * 7 else { continue }
                let recent = all[(end - rate * 2 / 5)..<end]
                let rms = sqrt(recent.reduce(Float(0)) { $0 + $1 * $1 } / Float(recent.count))
                guard rms < 0.012 else { continue }
                let c = end - rate / 5
                let (piece, voiced) = AudioRecorder.trimSilence(Array(all[cut..<c]))
                cut = c
                if voiced > 0.3 {
                    print(String(format: "  chunk %d sent at %.1fs (%.1fs of audio)", tasks.count + 1, Double(end) / 16000, Double(piece.count) / 16000))
                    tasks.append(Task { try await Transcriber.transcribe(samples: piece, endpoint: endpoint, vocabulary: []) })
                }
            }
            let released = Date()
            let (tail, _) = AudioRecorder.trimSilence(Array(all[cut...]))
            async let tailText = Transcriber.transcribe(samples: tail, endpoint: endpoint, vocabulary: [])
            var parts: [String] = []
            for t in tasks { parts.append(try await t.value) }
            parts.append(try await tailText)
            print("streamed: release → transcript \(ms(since: released)) (\(tasks.count) chunks + tail)")
            let fullStart = Date()
            let full = try await Transcriber.transcribe(samples: AudioRecorder.trimSilence(all).samples, endpoint: endpoint, vocabulary: [])
            print("one-shot: release → transcript \(ms(since: fullStart))")
            print("streamed text: \(parts.joined(separator: " "))")
            print("one-shot text: \(full)")
            return
        }

        if let dir = value("--benchmark") {
            try await Benchmark.run(directory: URL(fileURLWithPath: dir), compareFile: value("--compare").map { URL(fileURLWithPath: $0) })
            return
        }

        if CommandLine.arguments.contains("--check-update") {
            print(await Updater.shared.dryRun())
            return
        }
        // Website screenshots: one retina PNG per setup step, without the footer bar.
        if let dir = value("--render-onboarding-steps") {
            _ = NSApplication.shared
            for step in 0..<6 {
                let view = OnboardingView(initialStep: step) {}
                    .frame(width: 820, height: 580)
                    .frame(width: 820, height: 492, alignment: .top) // drop the footer buttons
                    .clipped()
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-\(step).png"))
                }
            }
            print("rendered setup steps to \(dir)")
            return
        }
        if let out = value("--render-onboarding") {
            _ = NSApplication.shared // the welcome step reads the app icon
            let view = HStack(alignment: .top, spacing: 16) {
                ForEach(0..<5, id: \.self) { step in
                    OnboardingView(initialStep: step) {}
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
            .background(Color.gray.opacity(0.3))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: out))
            }
            print("rendered \(out)")
            return
        }

        if let out = value("--render-pill") {
            PillPreview.render(to: URL(fileURLWithPath: out))
            print("rendered \(out)")
            return
        }

        if let question = value("--ask") {
            var ctx = FocusContext()
            ctx.windowTitle = value("--window") ?? ""
            let start = Date()
            let intent = try await Ask.route(question: question, selection: value("--selection") ?? "", context: ctx)
            print("ask [\(ms(since: start))]: \(intent)")
            return
        }

        if CommandLine.arguments.contains("--meeting"), let you = value("--you"), let them = value("--them") {
            // Builds a meeting from two pre-recorded tracks and runs the real processor on it.
            let id = "cli-test-\(Int(Date().timeIntervalSince1970))"
            let store = MeetingStore.shared
            let folder = store.folder(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (src, name) in [(you, "you.m4a"), (them, "them.m4a")] {
                try AudioRecorder.m4a(from: AudioRecorder.load(url: URL(fileURLWithPath: src))).write(to: folder.appendingPathComponent(name))
            }
            store.save(Meeting(id: id, title: "CLI test", date: Date(), duration: 60, status: .processing, appName: "Zoom", notes: "", transcript: ""))
            let start = Date()
            await MeetingProcessor.process(id)
            let m = store.meetings.first { $0.id == id }!
            print("meeting [\(m.status.rawValue), \(ms(since: start))] \(m.title)\n--- transcript ---\n\(m.transcript)\n--- clean ---\n\(m.cleanTranscript ?? "(none)")\n--- notes ---\n\(m.notes)\(m.error.map { "\nerror: " + $0 } ?? "")")
            if CommandLine.arguments.contains("--actions") {
                for action in [MeetingTools.Action.followUp, .slack] {
                    print("--- \(action.label) ---\n" + ((try? await MeetingTools.run(action, meeting: m, settings: settings)) ?? "(failed)"))
                }
                let renamed = MeetingTools.rename(m, from: m.speakers.first { $0.hasPrefix("Speaker") } ?? "Speaker 3", to: "Arjun")
                print("--- renamed speakers: \(renamed.speakers)")
            }
            if !CommandLine.arguments.contains("--keep") { store.delete(m) }
            return
        }

        if let path = value("--preview") {
            LivePreview.prepare(language: settings.language)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard LivePreview.isReady else { print("preview: on-device model not ready"); return }
            let samples = try AudioRecorder.load(url: URL(fileURLWithPath: path))
            let preview = LivePreview()
            var updates = 0
            preview.onText = { text in updates += 1; print("  live: \(text)") }
            preview.start()
            let start = Date()
            for chunkStart in stride(from: 0, to: samples.count, by: 1600) { // 100 ms chunks, real-time pace
                preview.feed(Array(samples[chunkStart..<min(samples.count, chunkStart + 1600)]))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 800_000_000)
            print("preview final [\(updates) updates, \(ms(since: start))]: \(preview.stop())")
            return
        }

        if let path = value("--file") {
            let url = URL(fileURLWithPath: path)
            let start = Date()
            let raw = try await Transcriber.transcribeFile(data: Data(contentsOf: url), filename: url.lastPathComponent,
                                                           endpoint: settings.endpoint, vocabulary: settings.dictionary)
            print("file raw [\(ms(since: start))]: \(raw)")
            let polished = await Pipeline.polish(raw: raw, context: FocusContext(), settings: settings, longForm: true)
            print("file final [\(polished.engine)]:\n\(polished.text)")
            return
        }
        var context = FocusContext()
        context.bundleID = value("--app") ?? ""
        context.appName = context.bundleID.components(separatedBy: ".").last ?? ""
        context.textBefore = value("--before")

        if CommandLine.arguments.contains("--models") {
            print(try await OpenAICompatible.models(settings.endpoint).sorted().joined(separator: "\n"))
            return
        }
        if let path = value("--diarize"), let starts = value("--starts") {
            let samples = try AudioRecorder.load(url: URL(fileURLWithPath: path))
            let times = starts.split(separator: ",").compactMap { Double($0) }
            let threshold = Float(value("--threshold") ?? "") ?? 0.42
            if CommandLine.arguments.contains("--dump") {
                for (i, t) in times.enumerated() {
                    let end = i + 1 < times.count ? times[i + 1] : Double(samples.count) / 16_000
                    let f = Diarization.fingerprint(samples[Int(t * 16_000)..<min(samples.count, Int(end * 16_000))])
                    print("F " + (f?.map { String(format: "%.3f", $0) }.joined(separator: " ") ?? "nil"))
                }
                return
            }
            let labels = Diarization.speakers(samples: samples, starts: times, threshold: threshold)
            print("speakers: \(labels.map { $0.map(String.init).joined(separator: " ") } ?? "one voice")")
            return
        }
        if let path = value("--whisper-local") {
            var start = Date()
            try await OnDeviceWhisper.download { p in if Int(p * 100) % 10 == 0 { print(String(format: "download %.0f%%", p * 100)) } }
            print("model ready [\(ms(since: start))]")
            for file in path.split(separator: ",") {
                let samples = AudioRecorder.trimSilence(try AudioRecorder.load(url: URL(fileURLWithPath: String(file)))).samples
                start = Date()
                let text = try await OnDeviceWhisper.transcribe(samples, language: value("--lang") ?? "", vocabulary: [])
                print("whisper-local [\(ms(since: start))]: \(text)")
            }
            return
        }
        if CommandLine.arguments.contains("--mic-info") {
            let current = AudioDevices.defaultInputID()
            let name = AudioDevices.inputs().first { $0.id == current }?.name ?? "none"
            print("default input: \(name), bluetooth: \(current.map(AudioDevices.isBluetooth) ?? false)")
            print("built-in mic: \(AudioDevices.builtInMic()?.name ?? "none")")
            for d in AudioDevices.inputs() { print("  • \(d.name): \(AudioDevices.kind(d))") }
            print("automatic: \(AudioDevices.automatic(preferBuiltIn: settings.preferBuiltInMic)?.name ?? "none"); ranked: \(AudioDevices.ranked(preferBuiltIn: settings.preferBuiltInMic).map(\.name))")
            print("mic in use by an app: \(AudioDevices.someoneIsRecording()); call app: \(MeetingDetector.callApp() ?? "none")")
            print("speakers: playing \(AudioDevices.outputIsPlaying) · headphones \(AudioDevices.outputIsHeadphones) · muted \(AudioDevices.outputMuted.map(String.init) ?? "?") · when playing: \(AppSettings.shared.playbackMode.label)")
            let uid = AudioDevices.preferredUID(chosen: settings.inputDeviceUID, preferBuiltIn: settings.preferBuiltInMic)
            print("Freshflo will record from: \(uid.isEmpty ? name : AudioDevices.inputs().first { $0.uid == uid }?.name ?? uid)")
            return
        }
        if let out = value("--render-styles") {
            StyleGallery.render(to: URL(fileURLWithPath: out))
            print("rendered \(out)")
            return
        }
        if CommandLine.arguments.contains("--mic-test") {
            // Records a few seconds the way a dictation does and reports what the mic delivered.
            let seconds = Double(value("--mic-test") ?? "") ?? 4
            let rec = AudioRecorder()
            rec.deviceUID = AudioDevices.preferredUID(chosen: AppSettings.shared.inputDeviceUID, preferBuiltIn: AppSettings.shared.preferBuiltInMic)
            let mute = CommandLine.arguments.contains("--mute") && !AudioDevices.outputIsHeadphones && AudioDevices.outputMuted == false
            if mute { AudioDevices.outputMuted = true }
            defer { if mute { AudioDevices.outputMuted = false } }
            var resets = 0, lost = 0
            rec.onEngineReset = { resets += 1 }
            rec.onDeviceLost = { lost += 1 }
            let name = AudioDevices.inputs().first { $0.uid == rec.deviceUID }?.name ?? "system default"
            print("recording \(seconds)s from: \(name) (talk now)" + (mute ? " · speakers muted" : ""))
            do { try rec.start() } catch { print("couldn't start: \(error)"); return }
            spinRunLoop(seconds)
            let (voiced, _) = rec.voiceSoFar
            let peak = rec.peakSoFar
            let s = rec.stop()
            let (trimmed, active) = AudioRecorder.trimSilence(s)
            let rms = sqrt(s.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, s.count)))
            print(String(format: "samples %.1fs · peak %.3f · rms %.4f · active sound %.1fs · voice %.1fs · kept %.1fs · engine resets %d · mic lost %d · speakers %@",
                         Double(s.count) / 16_000, peak, rms, active, voiced, Double(trimmed.count) / 16_000, resets, lost, mute ? "muted" : "playing"))
            print(peak < 0.0001 ? "⚠︎ mic delivered silence (muted, or no permission)" : voiced >= 0.3 ? "✓ heard a voice" : "· no voice heard (that's fine if you stayed quiet)")
            return
        }
        if let path = value("--polish-batch") {
            // Parity harness for other ports: one JSON object per line in, one per line out.
            // {"text", "tone", "lists", "email", "profanity", "grammar", "dictionary", "regional", "bullet"}
            guard let data = FileManager.default.contents(atPath: path), let body = String(data: data, encoding: .utf8) else { print("can't read"); return }
            for line in body.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let text = o["text"] as? String else { continue }
                let tone = Tone(rawValue: o["tone"] as? String ?? "casual") ?? .casual
                var opt = TextPolish.Options()
                opt.tone = tone
                opt.lists = o["lists"] as? Bool ?? true
                opt.email = o["email"] as? Bool ?? false
                opt.grammar = o["grammar"] as? Bool ?? true
                opt.profanity = ProfanityMode(rawValue: o["profanity"] as? String ?? "cleanUp") ?? .cleanUp
                opt.dictionary = o["dictionary"] as? [String] ?? []
                opt.bullet = o["bullet"] as? String ?? "• "
                let regional = RegionalFormat(rawValue: o["regional"] as? String ?? "") ?? .none
                let polished = TextPolish.apply(Regional.apply(text, regional), opt)
                let ruled = TextPolish.apply(Regional.apply(Cleanup.rules(CodeTerms.apply(SpokenEnglish.fix(text)), tone: tone), regional), opt)
                let detect = ListFormat.detect(text)
                let out: [String: Any] = ["polish": polished, "rules": ruled, "spoken": SpokenEnglish.fix(text),
                                          "listKind": detect.kind.map { $0 == .numbered ? "numbered" : "bulleted" } ?? "none", "listItems": detect.items,
                                          "fast": Cleanup.fastPath(CleanupInput(raw: text, tone: tone, context: FocusContext(), vocabulary: [], keepPhrases: [])) ?? NSNull()]
                if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
            }
            return
        }
        if let list = value("--voice-sense") {
            // Is there a person talking in each file? (pitch-based voice time, classifier scores, verdict)
            for path in list.split(separator: ",").map(String.init) {
                guard let s = try? AudioRecorder.load(url: URL(fileURLWithPath: path)) else { print("\(path): can't read"); continue }
                let t0 = Date()
                let v = VoiceSense.summarize(s)
                let tight = VoiceSense.tightenPauses(s)
                print(String(format: "%@  voiced %.1fs of %.1fs · speech %.2f · music %.2f · %@ · pauses %.1fs→%.1fs · %.0f ms",
                             URL(fileURLWithPath: path).lastPathComponent, v.voicedSeconds, Double(s.count) / 16_000, v.speechConfidence,
                             v.musicConfidence, v.hasHumanSpeech ? "HUMAN" : "no voice", Double(s.count) / 16_000, Double(tight.count) / 16_000,
                             Date().timeIntervalSince(t0) * 1000))
            }
            return
        }
        if let out = value("--render-appearance") {
            // A real window (Forms don't draw in ImageRenderer), captured offscreen.
            _ = NSApplication.shared
            let host = NSHostingView(rootView: Group { if CommandLine.arguments.contains("--general") { AnyView(GeneralTab()) } else { AnyView(AppearanceTab()) } }.frame(width: 640, height: 1500))
            let win = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 640, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFrontRegardless()
            spinRunLoop(1.0)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
            }
            return
        }
        if let out = value("--render-stats") {
            let renderer = ImageRenderer(content: StatsView(preview: StatsView.demo))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                try png?.write(to: URL(fileURLWithPath: out))
            }
            print("rendered \(out)")
            return
        }
        if CommandLine.arguments.contains("--seed-demo") {
            let seeded = await DemoMeetings.seed(rewriteNotes: CommandLine.arguments.contains("--with-ai"))
            print("seeded \(seeded.count) sample meetings:")
            seeded.forEach { print("  \(Knowledge.label($0))\($0.writtenBy.map { " · notes by \($0)" } ?? "")") }
            return
        }
        if CommandLine.arguments.contains("--remove-demo") {
            print("removed \(DemoMeetings.remove()) sample meetings")
            return
        }
        // --demo uses the sample meetings without saving them, so these paths can be tested without real notes.
        let meetings = CommandLine.arguments.contains("--demo") ? DemoMeetings.all() : MeetingStore.shared.meetings
        if CommandLine.arguments.contains("--commitments") {
            let parsed = Commitments.parse(meetings)
            print("parsed \(parsed.count) action items")
            let start = Date()
            let result = try await Commitments.organize(parsed, meetings: meetings, settings: settings)
            print("organized [\(ms(since: start))] by \(result.model):")
            for item in result.items {
                let bucket = Commitments.bucket(item, ticked: false)
                let due = item.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? (item.due.isEmpty ? "-" : item.due)
                print("  [\(bucket.title)] \(item.task) — \(item.owner.isEmpty ? "no owner" : item.owner), \(due) (\(item.meetingTitle))"
                      + (item.alsoIn.isEmpty ? "" : " also in: \(item.alsoIn.joined(separator: ", "))")
                      + (item.doneNote.map { " ✓ \($0)" } ?? ""))
            }
            return
        }
        if let query = value("--research") {
            let start = Date()
            let found = try await Tavily.search(query)
            print("tavily [\(ms(since: start))]: \(found.answer ?? "(no summary)")")
            found.results.enumerated().forEach { print("  [\($0.offset + 1)] \($0.element.title) — \($0.element.url)") }
            return
        }
        if let wanted = value("--next-step") {
            // A commitment id from --commitments, or words from its task ("acme quote").
            let (items, _) = Commitments.current(meetings)
            let words = wanted.lowercased().split(separator: " ")
            guard let item = items.first(where: { $0.id == wanted }) ?? items.first(where: { item in words.allSatisfy { item.task.lowercased().contains($0) } }) else {
                print("no commitment matches “\(wanted)”. Commitments:")
                items.forEach { print("  \($0.id)") }
                return
            }
            print("commitment: \(item.task) (\(item.meetingTitle))\nresearch: \(Tavily.isConfigured ? "on (Tavily)" : "off (no TAVILY_API_KEY)")")
            let start = Date()
            let proposal = try await CommitmentAgent.propose(item, meetings: meetings, settings: settings)
            print("next step [\(ms(since: start))] by \(proposal.proposedBy): \(proposal.kind.label)")
            print("  title: \(proposal.title)" + (proposal.to.isEmpty ? "" : "\n  to: \(proposal.to)")
                  + (proposal.due.map { "\n  due: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
            print(proposal.body.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 }.joined(separator: "\n"))
            proposal.sources.enumerated().forEach { print("  [\($0.offset + 1)] \($0.element)") }
            if CommandLine.arguments.contains("--queue") {
                AgentInbox.add(proposal)
                print("queued for approval in Open commitments")
            }
            return
        }
        if let path = value("--commitments-eval") {
            try await CommitmentsEval.run(path: path, settings: settings, runs: Int(value("--runs") ?? "") ?? 1,
                                          verbose: CommandLine.arguments.contains("--verbose"))
            return
        }
        if let question = value("--ask-meetings") {
            let start = Date()
            if CommandLine.arguments.contains("--stream") {
                nonisolated(unsafe) var shown = 0
                let answer = try await Knowledge.converse(history: [], question: question, meetings: meetings, settings: settings) { partial in
                    if partial.count > shown { print(partial.dropFirst(shown), terminator: ""); fflush(stdout); shown = partial.count }
                }
                print("\n[\(ms(since: start))] by \(answer.model ?? "-") · sources: \(answer.sources.map(Knowledge.label))")
                return
            }
            let answer = try await Knowledge.ask(question, meetings: meetings, settings: settings)
            print("answer [\(ms(since: start))]:\n\(answer.text)\nsources: \(answer.sources.map(Knowledge.label))")
            return
        }
        if let path = value("--grammar-eval") {
            try await GrammarEval.run(path: path, mode: value("--cleanup").flatMap(CleanupMode.init(rawValue:)), settings: settings,
                                      verbose: CommandLine.arguments.contains("--verbose"), paceMs: Int(value("--pace") ?? "") ?? 0)
            return
        }
        if let instruction = value("--command") {
            let selection = value("--selection")
            let start = Date()
            let output = try await Pipeline.command(instruction: instruction, selection: selection ?? "", context: context, settings: settings)
            print("command [\(ms(since: start))]: \(output)")
            return
        }

        guard let path = value("--transcribe") else { return }
        let vocab = value("--vocab")?.components(separatedBy: ",") ?? []
        let mode = value("--cleanup").flatMap(CleanupMode.init(rawValue:))
        let samples = try AudioRecorder.load(url: URL(fileURLWithPath: path))
        let (trimmed, voiced) = AudioRecorder.trimSilence(samples)
        print(String(format: "audio: %.2fs → trimmed %.2fs (voiced %.2fs)", Double(samples.count) / 16000, Double(trimmed.count) / 16000, voiced))
        if Double(trimmed.count) / 16000 > 10 {
            let aac = try AudioRecorder.m4a(from: trimmed)
            print("upload size: wav \(AudioRecorder.wav(from: trimmed).count / 1024) KB, aac \(aac.count / 1024) KB")
        }

        var start = Date()
        let transcript = try await Pipeline.transcribe(trimmed, settings: settings, forceLocal: CommandLine.arguments.contains("--local"), extraVocabulary: vocab) {
            print("status: \($0)")
        }
        print("raw [\(transcript.engine), \(ms(since: start))] (detected: \(transcript.language?.name ?? "?")): \(transcript.text)")

        start = Date()
        let result = await Pipeline.polish(raw: transcript.text, context: context, settings: settings, mode: mode, extraVocabulary: vocab)
        let final = context.spaced(result.text, fallbackTrailingSpace: false)
        print("final [\(result.engine), \(ms(since: start))]: \(final.debugDescription)")
    }

    private static func ms(since date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000)) ms"
    }
}

/// Lets the main run loop deliver audio and window events for a while. The command-line modes wait on the main
/// thread, so an async sleep would never wake up; this keeps the run loop turning instead.
private func spinRunLoop(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
