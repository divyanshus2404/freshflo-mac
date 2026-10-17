import AppKit
import AVFoundation

/// Drives one dictation: hotkey → record → transcribe → clean up (or run a command) → paste.
final class DictationController {
    enum State {
        case idle, recording, processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state); Self.busy = state != .idle }
    }
    /// True while a dictation is recording or processing (so call detection ignores Freshflo's own mic use).
    static var busy = false
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
    /// Watches for the natural end of a hands-free dictation.
    private var endTimer: Timer?
    /// Long dictations are transcribed in pieces at natural pauses while you're still talking,
    /// so releasing the key only waits for the last few seconds.
    private var chunkTimer: Timer?
    private var chunkCut = 0
    private var chunkTasks: [Task<String, Error>] = []
    private var previewEnabled = false
    /// Audio recorded on a mic that disappeared mid-dictation; the rest continues on the next best mic.
    private var carried: [Float] = []

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
    private var lastTapAt: Date?
    /// Speakers we muted for this dictation (so we only unmute what we muted).
    private var mutedSpeakers = false

    /// Music or a video playing through the speakers would be heard and typed: mute them while you talk.
    /// Headphones can't leak into the mic, so they're left alone. Restored as soon as you stop.
    /// Set when sound was playing and we should ask (once) what to do after this dictation.
    private var askAboutPlayback = false

    private func muteSpeakers() {
        guard !mutedSpeakers, !AudioDevices.outputIsHeadphones, AudioDevices.outputMuted == false else { return }
        switch settings.playbackMode {
        case .hear: return
        case .ask:
            if AudioDevices.outputIsPlaying { askAboutPlayback = true }
            return
        case .mute: break
        }
        AudioDevices.outputMuted = true
        mutedSpeakers = true
        UserDefaults.standard.set(true, forKey: "speakersMutedByFreshflo")
    }

    /// The first time something was playing during a dictation: ask whether to mute it from now on.
    private func askAboutPlaybackIfNeeded() {
        guard askAboutPlayback else { return }
        askAboutPlayback = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.settings.playbackMode == .ask, self.state == .idle else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Sound was playing on your Mac"
            alert.informativeText = "Your mic can hear music or videos from the speakers, and Freshflo may type them. Mute the speakers while you dictate? They come back as soon as you stop, and headphones are never muted. You can change this in Settings → General → Microphone."
            alert.addButton(withTitle: "Mute While I Talk")
            alert.addButton(withTitle: "Let Freshflo Hear It")
            self.settings.playbackMode = alert.runModal() == .alertFirstButtonReturn ? .mute : .hear
        }
    }

    private func restoreSpeakers() {
        guard mutedSpeakers else { return }
        AudioDevices.outputMuted = false
        mutedSpeakers = false
        UserDefaults.standard.removeObject(forKey: "speakersMutedByFreshflo")
    }

    /// After a crash mid-dictation the speakers could stay muted: undo that at launch.
    static func restoreSpeakersAfterCrash() {
        guard UserDefaults.standard.bool(forKey: "speakersMutedByFreshflo") else { return }
        AudioDevices.outputMuted = false
        UserDefaults.standard.removeObject(forKey: "speakersMutedByFreshflo")
    }

    /// The last dictation got only digital silence from the mic (shown as a problem with a fix in the menu).
    private(set) var micWasSilent = false
    private let maxDuration: TimeInterval = 20 * 60

    private static let scratchPhrases: Set<String> = [
        "scratch that", "scratch it", "delete that", "undo that", "remove that", "delete what i just said",
        "scratch that please", "delete that please",
    ]

    init() {
        recorder.onLevel = { [weak self] level in self?.pill.model.push(level) }
        recorder.onBands = { [weak self] bands in self?.pill.model.pushBands(bands) }
        recorder.onDeviceLost = { [weak self] in self?.continueOnNextMic() }
        recorder.onEngineReset = { [weak self] in self?.restartSameMic() }
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
            let lock = TalkKeyLogic.startsLocked(mode: settings.talkMode, lastTap: lastTapAt)
            lastTapAt = nil
            if settings.askModeEnabled, flags.contains(.maskShift) {
                begin(mode: .ask)
            } else {
                begin(mode: settings.commandModeEnabled && flags.contains(.maskControl) ? .command : .dictation)
            }
            if lock { lockHandsFree() }
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
        guard state == .recording, let pressedAt else { return }
        switch TalkKeyLogic.onRelease(mode: settings.talkMode, held: Date().timeIntervalSince(pressedAt), locked: locked) {
        case .finish: finish()
        case .lock: lockHandsFree()
        case .cancelQuietly:
            lastTapAt = Date()
            cancel(message: nil)
        case .ignore: break
        }
    }

    private func lockHandsFree() {
        guard state == .recording else { return }
        locked = true
        pill.model.locked = true
        endTimer?.invalidate()
        guard settings.autoStopHandsFree else { return }
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkNaturalEnd() }
    }

    /// Hands-free finishes when you've clearly stopped: after real speech, a pause as long as a person would wait,
    /// longer if the last words were "and…" or "so…". Whispered speech (no pitch) never triggers it.
    private func checkNaturalEnd() {
        guard state == .recording, locked else { endTimer?.invalidate(); endTimer = nil; return }
        let (voiced, since) = recorder.voiceSoFar
        guard voiced >= 0.8 else { return }
        let wait = VoiceSense.endPause(after: pill.model.liveText, base: settings.handsFreePause)
        if since >= wait { finish() }
    }

    /// The hands-free shortcut: start a hands-free dictation, or finish the current one.
    func toggleHandsFree() {
        guard !Self.paused else { return }
        switch state {
        case .idle:
            begin(mode: .dictation)
            lockHandsFree()
        case .recording: finish()
        default: break
        }
    }

    /// The cancel shortcut. True when there was something to cancel (the key is then not passed on).
    func cancelShortcut() -> Bool {
        guard state == .recording else { return false }
        cancel(message: "Cancelled")
        return true
    }

    func otherKeyDown(_ keyCode: Int64) {
        guard state == .recording else { return }
        if !locked, let pressedAt, Date().timeIntervalSince(pressedAt) < 0.6 {
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

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, settings.blockedApps.contains(id) {
            pill.flash("Freshflo is off in \(app.localizedName ?? "this app")", seconds: 1.4, isError: false)
            return
        }
        carried = []
        micWasSilent = false
        learner.check()
        let previewReady = LivePreview.isReady
        previewEnabled = (settings.livePreview || settings.showCaptions) && previewReady
        if previewEnabled { preview.start() }
        pill.model.captionsAvailable = previewReady
        recorder.deviceUID = AudioDevices.preferredUID(chosen: settings.inputDeviceUID, preferBuiltIn: settings.preferBuiltInMic)
        do {
            try recorder.start()
        } catch {
            restoreSpeakers()
            stopPreview()
            pill.flash(error.localizedDescription)
            return
        }
        // Capture after the mic is live so the first word isn't clipped.
        context = FocusContext.capture(app: NSWorkspace.shared.frontmostApplication, readText: settings.useScreenContext || command)
        if context.isSecureField {
            restoreSpeakers()
            _ = recorder.stop()
            stopPreview()
            pill.flash("Can't dictate into password fields")
            return
        }

        mode = newMode
        locked = false
        pressedAt = Date()
        state = .recording
        let style = settings.tone(for: context)
        pill.model.appLabel = context.appName.isEmpty ? style.shortLabel : "\(context.appName) · \(style.shortLabel)"
        pill.showRecording(mode: mode, locked: false, anchor: context.caretRect)
        play(.start)
        // After the start chime has played, so you still hear it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.muteSpeakers()
        }
        if settings.canUseCloud { OpenAICompatible.prewarm(settings.endpoint) }
        if settings.cleanupMode == .apple || (settings.cleanupMode == .auto && !settings.canUseCloud) || command { AppleModel.prewarm() }
        maxTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            guard self?.state == .recording else { return }
            self?.finish()
        }
        // Bluetooth mics can take a couple of seconds to start delivering sound, so only judge after 2.5 s.
        micCheck = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.checkMicIsAlive() }
        chunkCut = 0
        chunkTasks = []
        if settings.provider.isCloud, settings.canUseCloud {
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.cutChunkAtPause() }
        }
    }

    /// A muted or disconnected device delivers pure digital silence; recover instead of recording nothing.
    private func checkMicIsAlive() {
        guard state == .recording, recorder.peakSoFar < 0.0001 else { return }
        // A silent mic (a headset still switching modes, a muted interface): move to the next best mic and keep going.
        if let next = AudioDevices.fallback(after: recorder.deviceUID, preferBuiltIn: settings.preferBuiltInMic) {
            _ = recorder.stop()
            recorder.deviceUID = next.uid
            if (try? recorder.start()) != nil {
                pill.flash("That mic is silent, switched to \(next.name)", seconds: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.state == .recording else { return }
                    self.pill.showRecording(mode: self.mode, locked: self.locked)
                }
                return
            }
        }
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
        micWasSilent = true
        pill.model.liveText = "⚠︎ Your microphone is silent. Fix it from the menu bar."
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

    /// The mic disappeared or changed mid-dictation (AirPods connected, USB mic unplugged): keep what was said,
    /// and carry on with the next best mic. Streaming in pieces stops; the whole thing is transcribed at the end.
    /// macOS reset the audio engine but the mic is the same: carry on silently, keeping everything said so far.
    private func restartSameMic() {
        guard state == .recording else { return }
        carried += recorder.stop()
        stopChunking().tasks.forEach { $0.cancel() }
        do {
            try recorder.start()
        } catch {
            continueOnNextMic(force: true)
        }
    }

    private func continueOnNextMic(force: Bool = false) {
        guard state == .recording else { return }
        let lost = recorder.deviceUID
        if !force { carried += recorder.stop() }
        stopChunking().tasks.forEach { $0.cancel() }
        let uid = AudioDevices.preferredUID(chosen: settings.inputDeviceUID == lost ? "" : settings.inputDeviceUID, preferBuiltIn: settings.preferBuiltInMic)
        recorder.deviceUID = uid
        do {
            try recorder.start()
            // Only say so when it's genuinely a different mic.
            guard uid != lost else { return }
            let name = AudioDevices.inputs().first { $0.uid == uid }?.name ?? "the default mic"
            pill.flash("Mic changed, now using \(name)", seconds: 1.6, isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.state == .recording else { return }
                self.pill.showRecording(mode: self.mode, locked: self.locked)
            }
        } catch {
            finish()
        }
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
        restoreSpeakers()
        askAboutPlayback = false
        endTimer?.invalidate(); endTimer = nil
        chunkTasks.forEach { $0.cancel() }
        _ = stopChunking()
        maxTimer?.invalidate()
        micCheck?.invalidate()
        _ = recorder.stop()
        carried = []
        _ = stopPreview()
        state = .idle
        if let message { pill.flash(message, seconds: 1.2) } else { pill.hide() }
        play(.cancel)
    }

    private func finish() {
        restoreSpeakers()
        askAboutPlaybackIfNeeded()
        endTimer?.invalidate(); endTimer = nil
        maxTimer?.invalidate()
        micCheck?.invalidate()
        let captured = carried + recorder.stop()
        carried = []
        let chunks = stopChunking()
        let heard = stopPreview()
        play(.stop)
        let (trimmed, voiced) = AudioRecorder.trimSilence(captured)
        // Is a person actually talking? Clear speech skips the slower classifier; short or unclear clips get it,
        // so typing, a fan, music or a TV never get sent off to be "transcribed" into made-up words.
        let live = recorder.voiceSoFar.voiced
        let human = voiced >= 0.2 && (live >= 2.5 || VoiceSense.summarize(trimmed).hasHumanSpeech)
        guard human else {
            chunks.tasks.forEach { $0.cancel() }
            state = .idle
            pill.flash(voiced < 0.2 ? "Didn't catch that" : "Didn't hear anyone speaking", seconds: 1.6)
            return
        }
        let samples = VoiceSense.tightenPauses(trimmed)
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

            // Shown when it matters: a language other than English, or speaking one and writing another.
            let spoken = transcript.language ?? LanguageID.detect(text: transcript.text, whisperGuess: nil, hints: settings.spokenLanguages)
            let target = settings.outputLanguage.components(separatedBy: " (").first ?? ""
            var languageNote: String?
            if let spoken {
                if !target.isEmpty, spoken.name != target { languageNote = "\(spoken.name) → \(target)" }
                else if spoken.code != "en" || spoken.hinglish { languageNote = spoken.name }
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
            // Nowhere to type (the desktop, Finder): keep the thought in Scratchpad instead of losing it.
            if mode == .dictation, context.hasNoTextTarget {
                ScratchpadStore.shared.capture(output)
                history.add(HistoryItem(
                    date: Date(), appName: "Scratchpad", bundleID: context.bundleID, raw: transcript.text,
                    text: output.trimmingCharacters(in: .whitespaces), tone: settings.tone(for: context.bundleID),
                    duration: duration, cleanup: engine, mode: mode, transcriber: transcript.engine, latencyMs: ms(started)
                ))
                trace.outcome = "scratchpad"
                trace.totalMs = ms(started)
                Diagnostics.record(trace)
                pill.success("Saved to Scratchpad", typed: output)
                play(.done)
                return
            }
            let insertStarted = Date()
            let element = context.element
            let tail = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(30))
            let pasted = TextInserter.insert(output, verify: {
                // Only verifiable when the field exposes its text; otherwise assume success.
                guard let element, !tail.isEmpty, let now = FocusContext.textBeforeCaret(element) else { return true }
                return now.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(tail)
            }, onFailed: { [weak self] in
                DispatchQueue.main.async {
                    ScratchpadStore.shared.capture(output)
                    self?.pill.flash("This app blocked pasting: it's on your clipboard and in Scratchpad", seconds: 4)
                }
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
                duration: duration, cleanup: engine, mode: mode, transcriber: transcript.engine, latencyMs: trace.totalMs,
                languageNote: languageNote
            ))
            if pasted {
                let words = output.split(whereSeparator: \.isWhitespace).count
                let list = ListFormat.detect(output)
                var label = mode == .command ? "Done" : list.kind != nil ? "\(list.items)-item list" : "\(words) word\(words == 1 ? "" : "s")"
                if mode == .dictation, let note = languageNote { label = note + " · " + label }
                pill.success(label, typed: mode == .dictation ? output : nil)
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
    static let openPractice = Notification.Name("Freshflo.openPractice")
    static let toggleMeeting = Notification.Name("Freshflo.toggleMeeting")
    static let audioDevicesChanged = Notification.Name("Freshflo.audioDevicesChanged")
}
