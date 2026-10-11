import AppKit
import AVFoundation

/// Drives one dictation: hotkey → record → transcribe → clean up (or run a command) → paste.
final class DictationController {
    enum State {
        case idle, recording, processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    let pill = PillController()
    private let learner = CorrectionLearner()
    private let recorder = AudioRecorder()
    private let preview = LivePreview()
    private let settings = AppSettings.shared
    private let history = HistoryStore.shared

    private var locked = false
    private var mode: DictationMode = .dictation
    private var pressedAt: Date?
    private var context = FocusContext()
    private var maxTimer: Timer?
    private var micCheck: Timer?
    /// Long dictations are transcribed in pieces at natural pauses while you're still talking,
    /// so releasing the key only waits for the last few seconds.
    private var chunkTimer: Timer?
    private var chunkCut = 0
    private var chunkTasks: [Task<String, Error>] = []
    private var previewEnabled = false

    /// The most recent paste, so "scratch that" or "make that shorter" can act on it without selecting.
    private struct Insertion {
        let text: String
        let bundleID: String
        let date: Date
    }
    private var lastInsertion: Insertion?

    /// Audio from the last dictation that failed, so it can be retried from the menu (persisted across restarts).
    private(set) var lastFailed: (samples: [Float], context: FocusContext, mode: DictationMode)?

    /// Holding shorter than this counts as a tap, which switches to hands-free mode.
    private let tapThreshold: TimeInterval = 0.3
    private let maxDuration: TimeInterval = 20 * 60

    private static let scratchPhrases: Set<String> = [
        "scratch that", "scratch it", "delete that", "undo that", "remove that", "delete what i just said",
        "scratch that please", "delete that please",
    ]

    init() {
        recorder.onLevel = { [weak self] level in self?.pill.model.push(level) }
        recorder.onBands = { [weak self] bands in self?.pill.model.pushBands(bands) }
        recorder.onChunk = { [weak self] chunk in
            guard let self, self.previewEnabled else { return }
            self.preview.feed(chunk)
        }
        preview.onText = { [weak self] text in
            guard let self, self.state == .recording else { return }
            self.pill.model.liveText = text
        }
        learner.onLearn = { [weak self] word in
            guard let self, self.settings.autoLearn, self.settings.learn(word), self.state == .idle else { return }
            self.pill.flash("Learned “\(word)”", seconds: 1.8, isError: false)
        }
        lastFailed = FailedStore.load()
        LivePreview.prepare(language: settings.language)
    }

    // MARK: - Hotkey events

    /// Set while setup is testing the key, so pressing it there doesn't start a dictation.
    static var paused = false

    func hotkeyPressed(flags: CGEventFlags) {
        guard !Self.paused else { return }
        switch state {
        case .idle:
            if settings.askModeEnabled, flags.contains(.maskShift) {
                begin(mode: .ask)
            } else {
                begin(mode: settings.commandModeEnabled && flags.contains(.maskControl) ? .command : .dictation)
            }
        case .recording where locked:
            finish()
        default:
            break
        }
    }

    func modifiersChanged(_ flags: CGEventFlags) {
        guard state == .recording, mode == .dictation else { return }
        if settings.askModeEnabled, flags.contains(.maskShift) {
            mode = .ask
        } else if settings.commandModeEnabled, flags.contains(.maskControl) {
            mode = .command
        } else {
            return
        }
        pill.model.mode = mode
    }

    func hotkeyReleased() {
        guard state == .recording, !locked, let pressedAt else { return }
        if Date().timeIntervalSince(pressedAt) < tapThreshold {
            locked = true
            pill.model.locked = true
        } else {
            finish()
        }
    }

    func otherKeyDown(_ keyCode: Int64) {
        guard state == .recording else { return }
        if keyCode == 53 { // Escape
            cancel(message: "Cancelled")
        } else if !locked, let pressedAt, Date().timeIntervalSince(pressedAt) < 0.6 {
            // The hotkey was being used as a modifier in a shortcut, not to dictate.
            cancel(message: nil)
        }
    }

    // MARK: - Recording

    private func begin(mode newMode: DictationMode) {
        let command = newMode != .dictation
        switch Permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            Permissions.requestMicrophone()
            return
        default:
            pill.flash("Allow microphone access in System Settings")
            Permissions.openMicrophoneSettings()
            return
        }
        guard settings.isReady else {
            pill.flash("Add an API key in Settings")
            NotificationCenter.default.post(name: .openSettings, object: nil)
            return
        }

        learner.check()
        previewEnabled = settings.livePreview && LivePreview.isReady
        if previewEnabled { preview.start() }
        recorder.deviceUID = settings.inputDeviceUID
        do {
            try recorder.start()
        } catch {
            stopPreview()
            pill.flash(error.localizedDescription)
            return
        }
        // Capture after the mic is live so the first word isn't clipped.
        context = FocusContext.capture(app: NSWorkspace.shared.frontmostApplication, readText: settings.useScreenContext || command)
        if context.isSecureField {
            _ = recorder.stop()
            stopPreview()
            pill.flash("Can't dictate into password fields")
            return
        }

        mode = newMode
        locked = false
        pressedAt = Date()
        state = .recording
        pill.showRecording(mode: mode, locked: false, anchor: context.caretRect)
        play(.start)
        if settings.canUseCloud { OpenAICompatible.prewarm(settings.endpoint) }
        if settings.cleanupMode == .apple || (settings.cleanupMode == .auto && !settings.canUseCloud) || command { AppleModel.prewarm() }
        maxTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            guard self?.state == .recording else { return }
            self?.finish()
        }
        micCheck = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in self?.checkMicIsAlive() }
        chunkCut = 0
        chunkTasks = []
        if settings.provider.isCloud, settings.canUseCloud {
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.cutChunkAtPause() }
        }
    }

    /// A muted or disconnected device delivers pure digital silence; recover instead of recording nothing.
    private func checkMicIsAlive() {
        guard state == .recording, recorder.peakSoFar < 0.0001 else { return }
        if !recorder.deviceUID.isEmpty {
            _ = recorder.stop()
            recorder.deviceUID = ""
            if (try? recorder.start()) != nil {
                pill.flash("Selected mic is silent, switched to the system default", seconds: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.state == .recording else { return }
                    self.pill.showRecording(mode: self.mode, locked: self.locked)
                }
                return
            }
        }
        pill.model.liveText = "⚠︎ Your microphone is silent. Check that it isn't muted."
    }

    @discardableResult
    private func stopPreview() -> String {
        guard previewEnabled else { return "" }
        previewEnabled = false
        return preview.stop()
    }

    /// After ≥7 s of new audio, cut at the next pause and start transcribing that piece in the background.
    private func cutChunkAtPause() {
        guard state == .recording else { return }
        let rate = Int(AudioRecorder.sampleRate)
        let count = recorder.sampleCount
        guard count - chunkCut > rate * 7 else { return }
        let recent = recorder.samples(in: (count - rate * 2 / 5)..<count) // last 400 ms
        let rms = sqrt(recent.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, recent.count)))
        guard rms < 0.012 else { return }
        let cut = count - rate / 5 // middle of the pause
        let (piece, voiced) = AudioRecorder.trimSilence(recorder.samples(in: chunkCut..<cut))
        chunkCut = cut
        guard voiced > 0.3 else { return }
        let endpoint = settings.endpoint, vocabulary = settings.dictionary
        chunkTasks.append(Task {
            Transcriber.stripHallucinations(try await Transcriber.transcribe(samples: piece, endpoint: endpoint, vocabulary: vocabulary))
        })
    }

    private func stopChunking() -> (tasks: [Task<String, Error>], cut: Int) {
        chunkTimer?.invalidate()
        chunkTimer = nil
        let result = (chunkTasks, chunkCut)
        chunkTasks = []
        chunkCut = 0
        return result
    }

    private func cancel(message: String?) {
        chunkTasks.forEach { $0.cancel() }
        _ = stopChunking()
        maxTimer?.invalidate()
        micCheck?.invalidate()
        _ = recorder.stop()
        _ = stopPreview()
        state = .idle
        if let message { pill.flash(message, seconds: 1.2) } else { pill.hide() }
        play(.cancel)
    }

    private func finish() {
        maxTimer?.invalidate()
        micCheck?.invalidate()
        let captured = recorder.stop()
        let chunks = stopChunking()
        let heard = stopPreview()
        play(.stop)
        let (samples, voiced) = AudioRecorder.trimSilence(captured)
        guard voiced >= 0.2 else {
            chunks.tasks.forEach { $0.cancel() }
            state = .idle
            pill.flash("Didn't catch that", seconds: 1.4)
            return
        }
        let tail = chunks.tasks.isEmpty ? [] : Array(captured[min(chunks.cut, captured.count)...])
        process(samples: samples, context: context, mode: mode, liveText: heard, chunks: chunks.tasks, tail: tail)
    }

    func retryLast() {
        guard state == .idle, let failed = lastFailed else { return }
        process(samples: failed.samples, context: failed.context, mode: failed.mode, liveText: "")
    }

    private func process(samples: [Float], context: FocusContext, mode: DictationMode, liveText: String,
                         chunks: [Task<String, Error>] = [], tail: [Float] = []) {
        state = .processing
        pill.showProcessing("Transcribing…")
        Task { @MainActor in
            await self.run(samples: samples, context: context, mode: mode, liveText: liveText, chunks: chunks, tail: tail)
            self.state = .idle
        }
    }

    @MainActor
    private func run(samples: [Float], context: FocusContext, mode: DictationMode, liveText: String,
                     chunks: [Task<String, Error>] = [], tail: [Float] = []) async {
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let started = Date()
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
        var trace = DictationTrace(app: context.bundleID, mode: mode.rawValue, audioSeconds: (duration * 10).rounded() / 10, chunks: chunks.count)
        do {
            var chunked: Transcript?
            if !chunks.isEmpty {
                chunked = await assemble(chunks: chunks, tail: tail)
            }
            let transcript: Transcript
            if let chunked {
                transcript = chunked
            } else {
                transcript = try await Pipeline.transcribe(samples, settings: settings, liveFallback: liveText) { [weak self] status in
                    self?.pill.showProcessing(status)
                }
            }
            trace.transcriber = transcript.engine
            trace.transcribeMs = ms(started)
            guard !transcript.text.isEmpty else {
                trace.outcome = "empty"
                Diagnostics.record(trace)
                pill.flash("Didn't catch that", seconds: 1.4)
                return
            }
            let polishStarted = Date()
            lastFailed = nil
            FailedStore.clear()

            // "Scratch that": remove the previous dictation instead of typing the words.
            if mode == .dictation, Self.scratchPhrases.contains(SnippetExpander.normalize(transcript.text)) {
                scratchLastInsertion(context: context)
                trace.outcome = "scratch"
                trace.totalMs = ms(started)
                Diagnostics.record(trace)
                return
            }

            if mode == .ask {
                pill.hide()
                history.add(HistoryItem(
                    date: Date(), appName: context.appName, bundleID: context.bundleID, raw: transcript.text,
                    text: transcript.text, tone: settings.tone(for: context.bundleID),
                    duration: duration, cleanup: "ask", mode: .ask, transcriber: transcript.engine
                ))
                trace.outcome = "ask"
                trace.totalMs = ms(started)
                Diagnostics.record(trace)
                await Ask.handle(question: transcript.text, context: context)
                return
            }

            var output: String
            let engine: String
            var replacedRecent = false
            switch mode {
            case .ask:
                return
            case .dictation:
                if settings.cleanupMode != .off { pill.showProcessing("Polishing…") }
                let result = await Pipeline.polish(raw: transcript.text, context: context, settings: settings)
                output = context.spaced(result.text, fallbackTrailingSpace: settings.addTrailingSpace)
                engine = result.engine
            case .command:
                pill.showProcessing("Working on it…")
                var selection = context.selectedText
                // Nothing selected but you just dictated here: "make that shorter" edits that.
                if (selection ?? "").isEmpty, let recent = recentInsertion(for: context),
                   context.selectBeforeCaret(utf16Length: recent.text.utf16.count) {
                    selection = recent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    replacedRecent = true
                }
                if selection == nil { selection = await TextInserter.copySelection() }
                let result = try await Pipeline.command(instruction: transcript.text, selection: selection, context: context, settings: settings)
                let replacing = !(selection ?? "").isEmpty
                output = replacing ? result : context.spaced(result, fallbackTrailingSpace: false)
                if replacedRecent, let recent = lastInsertion {
                    // Keep the spacing the original insertion had.
                    if recent.text.first?.isWhitespace == true { output = " " + output }
                    if recent.text.last?.isWhitespace == true { output += " " }
                }
                engine = "command"
            }

            trace.cleanup = engine
            trace.polishMs = ms(polishStarted)
            let insertStarted = Date()
            let element = context.element
            let tail = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(30))
            let pasted = TextInserter.insert(output, verify: {
                // Only verifiable when the field exposes its text; otherwise assume success.
                guard let element, !tail.isEmpty, let now = FocusContext.textBeforeCaret(element) else { return true }
                return now.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(tail)
            }, onFailed: { [weak self] in
                self?.pill.flash("This app blocked pasting: text is on your clipboard, press ⌘V", seconds: 4)
            })
            trace.insertMs = ms(insertStarted)
            trace.totalMs = ms(started)
            trace.words = output.split(whereSeparator: \.isWhitespace).count
            trace.outcome = pasted ? "inserted" : "clipboard"
            Diagnostics.record(trace)
            if pasted {
                lastInsertion = Insertion(text: output, bundleID: context.bundleID, date: Date())
                if mode == .dictation, settings.autoLearn { learner.track(inserted: output, context: context) }
            }
            history.add(HistoryItem(
                date: Date(), appName: context.appName, bundleID: context.bundleID, raw: transcript.text,
                text: output.trimmingCharacters(in: .whitespaces), tone: settings.tone(for: context.bundleID),
                duration: duration, cleanup: engine, mode: mode, transcriber: transcript.engine, latencyMs: trace.totalMs
            ))
            if pasted {
                let words = output.split(whereSeparator: \.isWhitespace).count
                pill.success(mode == .command ? "Done" : "\(words) word\(words == 1 ? "" : "s")")
                play(.done)
            } else {
                pill.flash("Copied to clipboard — grant Accessibility to auto-paste", seconds: 3.5)
                Permissions.promptAccessibility()
            }
        } catch {
            trace.outcome = "failed"
            trace.error = error.localizedDescription
            trace.totalMs = ms(started)
            Diagnostics.record(trace)
            lastFailed = (samples, context, mode)
            FailedStore.save(samples: samples, context: context, mode: mode)
            play(.error)
            pill.flash("\(error.localizedDescription) — audio saved, retry from the menu", seconds: 4)
        }
    }

    /// Joins the pieces transcribed during recording with the final tail. Any failure falls back to a full transcription.
    @MainActor
    private func assemble(chunks: [Task<String, Error>], tail: [Float]) async -> Transcript? {
        let endpoint = settings.endpoint, vocabulary = settings.dictionary
        let (tailSamples, voiced) = AudioRecorder.trimSilence(tail)
        async let tailText: String = voiced > 0.2
            ? Transcriber.stripHallucinations(try await Transcriber.transcribe(samples: tailSamples, endpoint: endpoint, vocabulary: vocabulary))
            : ""
        do {
            var parts: [String] = []
            for task in chunks { parts.append(try await task.value) }
            parts.append(try await tailText)
            let text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return Transcript(text: text, engine: "\(endpoint.transcriptionModel) (×\(chunks.count + 1) streamed)")
        } catch {
            return nil
        }
    }

    /// The last insertion, if it was in the same app recently and the caret is still right after it.
    private func recentInsertion(for context: FocusContext) -> Insertion? {
        guard let last = lastInsertion, last.bundleID == context.bundleID,
              Date().timeIntervalSince(last.date) < 10 * 60, context.caretFollows(last.text) else { return nil }
        return last
    }

    @MainActor
    private func scratchLastInsertion(context: FocusContext) {
        guard let recent = recentInsertion(for: context) else {
            pill.flash("Nothing recent to scratch here", seconds: 1.6)
            return
        }
        if context.selectBeforeCaret(utf16Length: recent.text.utf16.count) {
            TextInserter.pressDelete()
        } else if recent.text.count <= 400 {
            TextInserter.pressDelete(count: recent.text.count)
        } else {
            pill.flash("Couldn't select the last dictation here", seconds: 2)
            return
        }
        lastInsertion = nil
        pill.flash("Scratched", seconds: 1.0, isError: false)
    }

    private func play(_ cue: SoundDesign.Cue) {
        SoundDesign.shared.play(cue, theme: settings.soundTheme)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("Freshflo.openSettings")
}
