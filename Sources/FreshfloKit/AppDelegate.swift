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
    private var meetingTimer: Timer?
    private var hotkeyRetry: Timer?
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setUpStatusItem()

        hotkey.onPress = { [weak self] flags in self?.dictation.hotkeyPressed(flags: flags) }
        hotkey.onModifiersChanged = { [weak self] flags in self?.dictation.modifiersChanged(flags) }
        hotkey.onRelease = { [weak self] in self?.dictation.hotkeyReleased() }
        hotkey.onOtherKeyDown = { [weak self] code in self?.dictation.otherKeyDown(code) }
        dictation.onStateChange = { [weak self] _ in self?.updateStatusIcon() }

        settings.$hotkey
            .dropFirst()
            .sink { [weak self] key in self?.hotkey.key = key }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings(tab: .general) }
        }

        startHotkey()

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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Freshflo")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Hold \(settings.hotkey.shortLabel) to dictate · tap for hands-free", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if settings.commandModeEnabled {
            let command = NSMenuItem(title: "Hold \(settings.hotkey.shortLabel) + Control for commands", action: nil, keyEquivalent: "")
            command.isEnabled = false
            menu.addItem(command)
        }
        if settings.askModeEnabled {
            let ask = NSMenuItem(title: "Hold \(settings.hotkey.shortLabel) + Shift to ask or take actions", action: nil, keyEquivalent: "")
            ask.isEnabled = false
            menu.addItem(ask)
        }

        if !hotkey.isRunning || !Permissions.accessibility {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(grantAccessibility)))
        }
        if Permissions.microphone != .authorized {
            menu.addItem(item("⚠︎ Grant Microphone Access…", #selector(grantMicrophone)))
        }
        if !settings.hasAPIKey {
            menu.addItem(item("⚠︎ Add API Key…", #selector(openSettings)))
        }

        menu.addItem(.separator())
        if dictation.lastFailed != nil {
            menu.addItem(item("Retry Last Dictation", #selector(retryLast)))
        }
        let paste = item("Paste Last Dictation", #selector(pasteLast))
        let copy = item("Copy Last Dictation", #selector(copyLast))
        paste.isEnabled = history.last != nil
        copy.isEnabled = history.last != nil
        menu.addItem(paste)
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
            recent.submenu = sub
            menu.addItem(recent)
        }

        menu.addItem(.separator())
        if MeetingController.shared.isRecording {
            let s = Int(MeetingController.shared.elapsed)
            menu.addItem(item(String(format: "■ Stop Meeting Notes (%d:%02d)", s / 60, s % 60), #selector(toggleMeeting)))
        } else {
            menu.addItem(item("● Start Meeting Notes", #selector(toggleMeeting)))
        }
        menu.addItem(item("Meeting Notes…", #selector(openMeetings)))
        menu.addItem(item("Transcribe Audio File…", #selector(transcribeFile)))
        menu.addItem(item("History…", #selector(openHistory)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Setup Guide…", #selector(openOnboarding)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Freshflo", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        return mi
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
                    dictation.pill.flash(warning ?? "Meeting notes started: recording you and the call", seconds: warning == nil ? 2 : 5, isError: warning != nil)
                } else {
                    dictation.pill.flash(warning ?? "Couldn't start recording", seconds: 3)
                }
            }
        }
    }

    @objc private func openMeetings() { showMeetings() }

    @objc private func openOnboarding() { showOnboarding() }

    private func showOnboarding(step: Int = 0) {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
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
