import AppKit
import SwiftUI
import Foundation

/// Headless test hook: runs the real pipeline on an audio file and prints each stage.
///   Freshflo --transcribe speech.aiff [--local] [--app com.apple.mail] [--before "text before cursor"]
///   Freshflo --command "make this formal" [--selection "hey whats up"]
public enum CLI {
    public static var isRequested: Bool {
        ["--transcribe", "--command", "--models", "--file", "--preview", "--ask", "--meeting", "--render-pill", "--stream-test", "--render-onboarding", "--benchmark", "--check-update"].contains(where: CommandLine.arguments.contains)
    }

    /// Shows the real floating indicator inside a proper app run loop with synthetic speech (performance checks).
    public static var isDemoRequested: Bool { CommandLine.arguments.contains("--demo-pill") }

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
        let savedLanguage = settings.outputLanguage, savedRegion = settings.regionalFormat
        defer {
            settings.outputLanguage = savedLanguage
            settings.regionalFormat = savedRegion
        }
        let savedCleanupModel = settings.cleanupModel
        defer { settings.cleanupModel = savedCleanupModel }
        if let model = value("--cleanup-model") { settings.cleanupModel = model }
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
            print("meeting [\(m.status.rawValue), \(ms(since: start))] \(m.title)\n--- transcript ---\n\(m.transcript)\n--- notes ---\n\(m.notes)\(m.error.map { "\nerror: " + $0 } ?? "")")
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
        print("raw [\(transcript.engine), \(ms(since: start))]: \(transcript.text)")

        start = Date()
        let result = await Pipeline.polish(raw: transcript.text, context: context, settings: settings, mode: mode, extraVocabulary: vocab)
        let final = context.spaced(result.text, fallbackTrailingSpace: false)
        print("final [\(result.engine), \(ms(since: start))]: \(final.debugDescription)")
    }

    private static func ms(since date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000)) ms"
    }
}
