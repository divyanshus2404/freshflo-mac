import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    override public init() { super.init() }

    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let dictation = DictationController()
    private lazy var hotkey = HotkeyMonitor(key: settings.hotkey)
    private let router = SettingsRouter()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var meetingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var scratchpadWindow: NSWindow?
    private var meetingTimer: Timer?
    private var hotkeyRetry: Timer?
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppMover.moveIfNeeded()
        DictationController.restoreSpeakersAfterCrash()
        AppSettings.shared.appAppearance.apply()
        installMainMenu()
        setUpStatusItem()

        hotkey.onPress = { [weak self] flags in self?.dictation.hotkeyPressed(flags: flags) }
        hotkey.onModifiersChanged = { [weak self] flags in self?.dictation.modifiersChanged(flags) }
        hotkey.onRelease = { [weak self] in self?.dictation.hotkeyReleased() }
        hotkey.onOtherKeyDown = { [weak self] code in self?.dictation.otherKeyDown(code) }
        hotkey.onAction = { [weak self] action in self?.perform(action) ?? false }
        applyShortcuts()
        CommandPalette.shared.commands = { [weak self] in self?.paletteCommands() ?? [] }
        NotificationCenter.default.addObserver(forName: .openFeedbackWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openFeedback() }
        }
        // Asked at most once, a while after launch so it never interrupts the first dictation of the day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { EnjoyPrompt.maybeAsk() }
        NotificationCenter.default.addObserver(forName: .openPractice, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openPractice() }
        }
        settings.$talkCombo.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyShortcuts() }.store(in: &cancellables)
        settings.$shortcuts.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyShortcuts() }.store(in: &cancellables)
        settings.$clearedShortcuts.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyShortcuts() }.store(in: &cancellables)
        dictation.onStateChange = { [weak self] _ in self?.updateStatusIcon() }

        settings.$hotkey
            .dropFirst()
            .sink { [weak self] key in self?.hotkey.key = key }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: .toggleMeeting, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleMeeting() }
        }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings(tab: .general) }
        }

        startHotkey()
        Updater.shared.onChange = { [weak self] in self?.updateStatusIcon() }
        Updater.shared.start()
        Insights.start()
        FolderSync.shared.start()
        AudioDevices.watch { NotificationCenter.default.post(name: .audioDevicesChanged, object: nil) }
        MeetingDetector.shared.start()
        OnDeviceWhisper.prewarm()
        WeeklyRecap.shared.onOpen = { [weak self] in self?.openStats() }
        WeeklyRecap.shared.start()

        // People who already set things up before onboarding existed skip it.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "onboarded"), settings.isReady, Permissions.accessibility, Permissions.microphone == .authorized {
            defaults.set(true, forKey: "onboarded")
        }
        // Coming from the old app name: settings carried over, but macOS needs the permissions granted again.
        if defaults.bool(forKey: LegacyMigration.needsPermissionsKey) {
            defaults.removeObject(forKey: LegacyMigration.needsPermissionsKey)
            if !(Permissions.accessibility && Permissions.microphone == .authorized) {
                showOnboarding(step: 1)
                return
            }
        }
        if defaults.bool(forKey: "onboarded") { WhatsNew.showIfUpdated() } else { defaults.set(Updater.currentVersion, forKey: "lastRunVersion") }
        if !defaults.bool(forKey: "onboarded") {
            showOnboarding()
        } else if !settings.isReady {
            showSettings(tab: .general)
        }
    }

    // MARK: - Hotkey

    /// The event tap can't be created until Accessibility is granted, so keep retrying quietly.
    private func startHotkey() {
        if hotkey.start() {
            hotkeyRetry?.invalidate()
            hotkeyRetry = nil
            updateStatusIcon()
            return
        }
        guard hotkeyRetry == nil else { return }
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startHotkey() }
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol: String
        if MeetingController.shared.isRecording, dictation.state == .idle {
            let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording meeting")
            image?.isTemplate = true
            statusItem.button?.image = image
            let s = Int(MeetingController.shared.elapsed)
            statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
            return
        }
        statusItem.button?.title = ""
        switch dictation.state {
        case .recording: symbol = "waveform.circle.fill"
        case .processing: symbol = "ellipsis.circle"
        case .idle: symbol = hotkey.isRunning ? "waveform" : "exclamationmark.triangle"
        }
        let trouble = dictation.state == .idle && !problems().isEmpty
        statusItem.button?.toolTip = trouble ? "Freshflo needs attention: click for the fix"
            : (settings.provider == .local || OnDeviceWhisper.isActive ? "Freshflo · on this Mac" : "Freshflo · \(settings.provider.label)")
        if trouble {
            let warn = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Freshflo needs attention")
            warn?.isTemplate = true
            statusItem.button?.image = warn
            return
        }
        let image = dictation.state == .idle && hotkey.isRunning
            ? BrandMark.menuBarImage
            : NSImage(systemSymbolName: symbol, accessibilityDescription: "Freshflo")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Things that stop Freshflo working right now, each with the one click that fixes it.
    private func problems() -> [Problem] {
        var list: [Problem] = []
        if !hotkey.isRunning || !Permissions.accessibility {
            list.append(Problem(id: "ax", title: "Freshflo can't see your talk key", fix: "Allow Accessibility…") { [weak self] in self?.grantAccessibility() })
        }
        if Permissions.microphone != .authorized {
            list.append(Problem(id: "mic", title: "No microphone access", fix: "Allow Microphone…") { [weak self] in self?.grantMicrophone() })
        }
        if !settings.isReady {
            if OnDeviceWhisper.isDownloaded {
                list.append(Problem(id: "engine", title: "No speech engine set up", fix: "Use On-Device Whisper") { [weak self] in
                    self?.settings.provider = .local; self?.settings.useOnDeviceWhisper = true })
            } else {
                list.append(Problem(id: "engine", title: "No speech engine set up", fix: "Finish Setup…") { [weak self] in self?.openOnboarding() })
            }
        }
        if dictation.micWasSilent {
            if let mic = AudioDevices.builtInMic(), mic.uid != recorderUIDHint {
                list.append(Problem(id: "silent", title: "Your mic was silent", fix: "Use \(mic.name)") { [weak self] in
                    self?.settings.inputDeviceUID = mic.uid })
            } else {
                list.append(Problem(id: "silent", title: "Your mic was silent", fix: "Open Sound Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) })
            }
        }
        if dictation.lastFailed != nil {
            list.append(Problem(id: "failed", title: "Your last dictation didn't go through", fix: "Retry It") { [weak self] in self?.retryLast() })
        }
        return list
    }
    private var recorderUIDHint: String { AudioDevices.preferredUID(chosen: settings.inputDeviceUID, preferBuiltIn: settings.preferBuiltInMic) }

    @objc private func runProblemFix(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = problems().first(where: { $0.id == id }) else { return }
        p.action()
        updateStatusIcon()
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. Anything wrong, with its fix, first.
        for p in problems() {
            let title = NSMenuItem(title: "⚠︎ " + p.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let fix = item("    " + p.fix, #selector(runProblemFix(_:)))
            fix.representedObject = p.id
            menu.addItem(fix)
        }
        if let update = Updater.shared.available {
            menu.addItem(item(Updater.shared.installing ? "Installing Freshflo \(update.version)…" : "⬆︎ Update to Freshflo \(update.version)…", #selector(installUpdate)))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        // 2. Status: how to talk, where it runs, and today's progress.
        let header = NSMenuItem(title: settings.talkMode.hint(settings.talkKeyLabel), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let stats = UsageStats.shared
        let today = stats.today, streak = stats.streak, week = stats.thisWeek
        var line = settings.provider == .local || OnDeviceWhisper.isActive ? "🔒 On this Mac" : "☁︎ \(settings.provider.label)"
        if today.words > 0 { line += " · today \(today.words.formatted()) words" }
        if streak >= 2 { line += " · 🔥 \(streak)" }
        let status = NSMenuItem(title: line, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.toolTip = week.words > 0 ? "This week: \(week.words.formatted()) words · \(week.minutesSaved) min saved" : nil
        menu.addItem(status)

        // 3. The things you do every day.
        menu.addItem(.separator())
        let paste = item("Paste Last Dictation", #selector(pasteLast))
        paste.isEnabled = history.last != nil
        menu.addItem(paste)
        let copy = item("Copy Last Dictation", #selector(copyLast))
        copy.isEnabled = history.last != nil
        copy.isAlternate = true
        copy.keyEquivalentModifierMask = .option
        menu.addItem(copy)
        if !history.items.isEmpty {
            let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for entry in history.items.prefix(8) {
                let title = entry.text.count > 60 ? String(entry.text.prefix(60)) + "…" : entry.text
                let mi = item(title.replacingOccurrences(of: "\n", with: " "), #selector(copyEntry(_:)))
                mi.representedObject = entry.text
                mi.toolTip = "Click to copy"
                sub.addItem(mi)
            }
            sub.addItem(.separator())
            sub.addItem(item("All History…", #selector(openHistory)))
            recent.submenu = sub
            menu.addItem(recent)
        }
        if MeetingController.shared.isRecording {
            let s = Int(MeetingController.shared.elapsed)
            menu.addItem(item(String(format: "■ Stop Meeting Notes (%d:%02d)", s / 60, s % 60), #selector(toggleMeeting)))
        } else {
            menu.addItem(item("● Start Meeting Notes", #selector(toggleMeeting)))
        }
        menu.addItem(item("Scratchpad…", #selector(openScratchpad)))
        let find = item("Find Anything…", #selector(openPalette))
        if let k = settings.shortcut(.palette) { find.title += "  " + k.label }
        menu.addItem(find)

        // 4. Everything else, one level down.
        menu.addItem(.separator())
        let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let t = NSMenu()
        t.addItem(item("Meeting Notes…", #selector(openMeetings)))
        t.addItem(item("Transcribe Audio File…", #selector(transcribeFile)))
        t.addItem(item("Your Week…", #selector(openStats)))
        t.addItem(item("History…", #selector(openHistory)))
        t.addItem(.separator())
        let captions = item("Live Captions", #selector(toggleCaptions))
        captions.state = settings.showCaptions ? .on : .off
        t.addItem(captions)
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let off = settings.blockedApps.contains(id)
            let toggle = item(off ? "Turn On in \(app.localizedName ?? id)" : "Turn Off in \(app.localizedName ?? id)", #selector(toggleBlocked(_:)))
            toggle.representedObject = id
            t.addItem(toggle)
        }
        tools.submenu = t
        menu.addItem(tools)
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let h = NSMenu()
        let tip = NSMenuItem(title: "💡 " + Tips.today(key: settings.talkKeyLabel), action: nil, keyEquivalent: "")
        tip.isEnabled = false
        h.addItem(tip)
        if settings.commandModeEnabled {
            let c = NSMenuItem(title: "Hold \(settings.talkKeyLabel) + Control for commands", action: nil, keyEquivalent: ""); c.isEnabled = false; h.addItem(c)
        }
        if settings.askModeEnabled {
            let a = NSMenuItem(title: "Hold \(settings.talkKeyLabel) + Shift to ask or take actions", action: nil, keyEquivalent: ""); a.isEnabled = false; h.addItem(a)
        }
        h.addItem(.separator())
        h.addItem(item("Practice Dictating…", #selector(openPractice)))
        h.addItem(item("Setup Guide…", #selector(openOnboarding)))
        h.addItem(item("Contact Support…", #selector(openFeedback)))
        h.addItem(item("Share Freshflo…", #selector(shareApp)))
        h.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        help.submenu = h
        menu.addItem(help)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Freshflo", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    // MARK: - Find anything (⌘K) and practice

    @objc private func openPalette() { CommandPalette.shared.toggle() }

    private var practiceWindow: NSWindow?
    @objc private func openPractice() {
        if practiceWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Practice"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PracticeView())
            w.center()
            practiceWindow = w
        } else {
            practiceWindow?.contentView = NSHostingView(rootView: PracticeView())
        }
        NSApp.activate(ignoringOtherApps: true)
        practiceWindow?.makeKeyAndOrderFront(nil)
    }

    private func paletteCommands() -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        list.append(
            PaletteCommand(id: "paste", title: "Paste last dictation", keywords: "insert again", symbol: "doc.on.clipboard") { [weak self] in self?.pasteLastNow() })
        list.append(
            PaletteCommand(id: "copy", title: "Copy last dictation", keywords: "clipboard", symbol: "doc.on.doc") { [weak self] in self?.copyLast() })
        list.append(
            PaletteCommand(id: "meeting", title: MeetingController.shared.isRecording ? "Stop meeting notes" : "Start meeting notes", keywords: "record call zoom meet", symbol: "record.circle") { [weak self] in self?.toggleMeeting() })
        list.append(
            PaletteCommand(id: "meetings", title: "Meeting notes", subtitle: "Past meetings", keywords: "summary action items", symbol: "person.2.wave.2") { [weak self] in self?.openMeetings() })
        list.append(
            PaletteCommand(id: "scratch", title: "Scratchpad", keywords: "notes write", symbol: "square.and.pencil") { [weak self] in self?.openScratchpad() })
        list.append(
            PaletteCommand(id: "file", title: "Transcribe an audio file", keywords: "mp3 wav m4a import", symbol: "waveform") { [weak self] in self?.transcribeFile() })
        list.append(
            PaletteCommand(id: "week", title: "Your week", subtitle: "Words and time saved", keywords: "stats streak", symbol: "chart.bar") { [weak self] in self?.openStats() })
        list.append(
            PaletteCommand(id: "captions", title: settings.showCaptions ? "Turn off live captions" : "Turn on live captions", keywords: "subtitles", symbol: "captions.bubble") { [weak self] in self?.toggleCaptions() })
        list.append(
            PaletteCommand(id: "practice", title: "Practice dictating", keywords: "tutorial learn help", symbol: "graduationcap") { [weak self] in self?.openPractice() })
        list.append(
            PaletteCommand(id: "themes", title: "Get more themes", subtitle: "freshflo.vercel.app/themes", keywords: "colour color download", symbol: "paintpalette") {
                NSWorkspace.shared.open(URL(string: "https://freshflo.vercel.app/themes")!) })
        list.append(
            PaletteCommand(id: "feedback", title: "Send feedback", keywords: "bug report idea", symbol: "envelope") { [weak self] in self?.openFeedback() })
        list.append(
            PaletteCommand(id: "update", title: "Check for updates", keywords: "version", symbol: "arrow.down.circle") { [weak self] in self?.checkForUpdates() })
        list.append(
            PaletteCommand(id: "setup", title: "Setup guide", keywords: "onboarding permissions", symbol: "list.bullet.clipboard") { [weak self] in self?.openOnboarding() })
        for t in IndicatorTheme.allCases where t != .custom {
            list.append(PaletteCommand(id: "theme-\(t.rawValue)", title: "Theme: \(t.label)", keywords: "colour color appearance", symbol: "circle.lefthalf.filled") { [weak self] in
                self?.settings.indicatorTheme = t })
        }
        for e in SettingsIndex.entries {
            list.append(PaletteCommand(id: "set-" + e.title, title: e.title, subtitle: "Settings → " + SettingsSearchResults.tabName(e.tab), keywords: e.keywords, symbol: "gearshape") { [weak self] in
                if e.advanced { self?.settings.showAdvanced = true }
                self?.showSettings(tab: e.tab) })
        }
        for p in problems() {
            list.insert(PaletteCommand(id: "fix-" + p.id, title: p.fix, subtitle: p.title, keywords: "fix problem", symbol: "exclamationmark.triangle") { p.action() }, at: 0)
        }
        return list
    }

    private func pasteLastNow() {
        guard let text = history.last?.text else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { TextInserter.insert(text + (self.settings.addTrailingSpace ? " " : "")) }
    }

    @objc private func toggleBlocked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let i = settings.blockedApps.firstIndex(of: id) { settings.blockedApps.remove(at: i) } else { settings.blockedApps.append(id) }
    }

    @objc private func toggleCaptions() {
        settings.showCaptions.toggle()
        guard settings.showCaptions else { return }
        Task { @MainActor in
            _ = await LocalSpeech.requestAuthorization()
            LivePreview.prepare(language: settings.language)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: key)
        mi.target = target ?? self
        return mi
    }

    @objc private func installUpdate() {
        guard let release = Updater.shared.available else { return }
        Task { await Updater.shared.install(release) }
    }

    @objc private func checkForUpdates() {
        Task { await Updater.shared.check(userInitiated: true) }
    }

    @objc private func grantAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func grantMicrophone() {
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone()
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    /// freshflo:// links. Only theme installs for now; always asks first, since any website can open a link.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let theme = UserTheme.from(url: url) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Add the “\(theme.name)” theme?"
            alert.informativeText = "It changes the colours of your dictation bar. You can switch back any time in Settings → Appearance."
            alert.addButton(withTitle: "Add and Use")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { continue }
            var t = theme
            if let i = settings.savedThemes.firstIndex(where: { $0.name == t.name }) {
                t.id = settings.savedThemes[i].id
                settings.savedThemes[i] = t
            } else {
                settings.savedThemes.append(t)
            }
            t.id = settings.customTheme.id
            settings.customTheme = t
            settings.indicatorTheme = .custom
            showSettings(tab: .appearance)
        }
    }

    private func applyShortcuts() {
        hotkey.combo = settings.talkCombo
        var map: [ShortcutAction: KeyCombo] = [:]
        for a in ShortcutAction.allCases { if let c = settings.shortcut(a) { map[a] = c } }
        hotkey.actions = map
    }

    /// Runs a global shortcut. Returns true when it was used (the key press is then not passed to the app).
    private func perform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .cancel: return dictation.cancelShortcut()
        case .handsFree: dictation.toggleHandsFree()
        case .pasteLast:
            guard let text = history.last?.text else { return false }
            TextInserter.insert(text + (settings.addTrailingSpace ? " " : ""))
        case .meeting: toggleMeeting()
        case .scratchpad: openScratchpad()
        case .palette: CommandPalette.shared.toggle()
        }
        return true
    }

    @objc private func pasteLast() {
        guard let text = history.last?.text else { return }
        // Give the menu time to close so focus returns to the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            TextInserter.insert(text + (self.settings.addTrailingSpace ? " " : ""))
        }
    }

    @objc private func toggleMeeting() {
        Task { @MainActor in
            let meetings = MeetingController.shared
            if meetings.isRecording {
                meetingTimer?.invalidate()
                meetingTimer = nil
                updateStatusIcon()
                dictation.pill.flash("Writing meeting notes…", seconds: 2.5, isError: false)
                showMeetings()
                await meetings.stop()
            } else {
                let warning = await meetings.start()
                if meetings.isRecording {
                    meetingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateStatusIcon() }
                    }
                    updateStatusIcon()
                    let call = meetings.status.sources.first.map { "you and \($0)" } ?? "you and the call"
                    dictation.pill.flash(warning ?? "Meeting notes started: recording \(call)", seconds: warning == nil ? 2 : 5, isError: warning != nil)
                    showMeetings()
                } else {
                    dictation.pill.flash(warning ?? "Couldn't start recording", seconds: 3)
                }
            }
        }
    }

    @objc private func openMeetings() { showMeetings() }

    @objc private func openOnboarding() { showOnboarding() }

    @objc func openScratchpad() {
        if scratchpadWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Scratchpad"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("FreshfloScratchpad")
            window.contentView = NSHostingView(rootView: ScratchpadView())
            window.center()
            scratchpadWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        scratchpadWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func shareApp() {
        WeeklyRecap.share(from: statusItem.button)
    }

    @objc func openStats() {
        if statsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.center()
            statsWindow = window
        }
        statsWindow?.contentView = NSHostingView(rootView: StatsView())
        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openFeedback() {
        if feedbackWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 430), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.center()
            feedbackWindow = window
        }
        // A fresh form each time it opens.
        feedbackWindow?.contentView = NSHostingView(rootView: FeedbackView { [weak self] in self?.feedbackWindow?.close() })
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding(step: Int = 0) {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .aqua) // setup always uses the light brand look
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(initialStep: step) { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboarded")
                self?.onboardingWindow?.close()
            })
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func showMeetings() {
        if meetingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Meeting Notes"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MeetingsView())
            window.center()
            meetingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        meetingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func transcribeFile() {
        DispatchQueue.main.async { FileTranscription.pickAndTranscribe() }
    }

    @objc private func retryLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.dictation.retryLast() }
    }

    @objc private func copyLast() {
        guard let text = history.last?.text else { return }
        copy(text)
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { copy(text) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSettings() { showSettings(tab: .general) }
    @objc private func openHistory() { showSettings(tab: .history) }

    // MARK: - Windows

    private func showSettings(tab: SettingsTab) {
        router.tab = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Freshflo"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(router: router))
            window.contentMinSize = NSSize(width: 560, height: 480)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Accessory apps still need an Edit menu for ⌘C/⌘V/⌘A to work in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Freshflo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
