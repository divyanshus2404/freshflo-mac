import AppKit
import ApplicationServices
import SwiftUI

/// Notices when you join a call (a meeting app or a meeting tab is open and something is using the microphone)
/// and offers to take meeting notes, once per call. Nothing is recorded until you click Start.
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()

    private var timer: Timer?
    private var offeredThisCall = false
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Browser tabs that are calls, by window title.
    private static let callTabs: [(pattern: String, name: String)] = [
        (#"\bMeet\b|meet\.google\.com"#, "Google Meet"), (#"Microsoft Teams|\| Teams"#, "Microsoft Teams"), (#"\bZoom\b"#, "Zoom"),
        (#"Whereby"#, "Whereby"), (#"Jitsi"#, "Jitsi Meet"), (#"Webex"#, "Webex"), (#"Gather"#, "Gather"), (#"Huddle"#, "Slack huddle"),
    ]

    /// Always open whether or not you're on a call, so they only count when they're in front.
    private static let chatApps: Set<String> = ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord", "com.skype.skype"]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard AppSettings.shared.offerMeetingNotes, !MeetingController.shared.isRecording else {
            if MeetingController.shared.isRecording { hide() }
            return
        }
        // Freshflo's own dictation uses the mic too; don't mistake it for a call.
        guard !DictationController.busy else { return }
        let micBusy = AudioDevices.someoneIsRecording()
        guard micBusy, let app = Self.callApp() else {
            if !micBusy { offeredThisCall = false; hide() }
            return
        }
        guard !offeredThisCall else { return }
        offeredThisCall = true
        show(app)
    }

    /// The call app that's open right now: a meeting app, or a browser showing a meeting tab.
    static func callApp() -> String? {
        let running = NSWorkspace.shared.runningApplications
        // Apps that only run during calls count on their own; chat apps that are always open need the mic in use (checked by the caller).
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for app in running {
            guard let id = app.bundleIdentifier, let name = MeetingRecorder.meetingApps[id] else { continue }
            if chatApps.contains(id), id != front { continue }
            return name
        }
        for app in running where PromptMode.browsers.contains(app.bundleIdentifier ?? "") {
            let title = windowTitle(app)
            for tab in callTabs where title.range(of: tab.pattern, options: .regularExpression) != nil { return tab.name }
        }
        return nil
    }

    private static func windowTitle(_ app: NSRunningApplication) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return "" }
        return title as? String ?? ""
    }

    // MARK: The offer

    private func show(_ app: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: MeetingOffer(app: app, start: { [weak self] in
            self?.hide()
            NotificationCenter.default.post(name: .toggleMeeting, object: nil)
        }, dismiss: { [weak self] in self?.hide() }, never: { [weak self] in
            AppSettings.shared.offerMeetingNotes = false
            self?.hide()
        }))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 104), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct MeetingOffer: View {
    let app: String
    let start: () -> Void
    let dismiss: () -> Void
    let never: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.mic").font(.system(size: 18)).foregroundStyle(Brand.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(app) call detected").font(.system(size: 13, weight: .semibold))
                    Text("Take notes with who said what?").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Don't offer again", action: never).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Not now", action: dismiss)
                Button("Start notes", action: start).buttonStyle(.borderedProminent).tint(Brand.mint)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340, height: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
