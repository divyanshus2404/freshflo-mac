import AppKit
import SwiftUI

// MARK: - Controller

/// Floating, non-activating indicator.
final class PillController {
    static let bottomInset: CGFloat = 22
    static let leadingInset: CGFloat = 40
    private static let capsuleHeight: CGFloat = 32

    let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    /// Caret rect to appear next to for the current dictation (nil = bottom of the screen).
    private var anchor: CGRect?
    /// Bumped on every show/hide so a fade-out finishing late can't hide a newer indicator.
    private var generation = 0

    init() {
        // Extra room around the capsule so the glow is never clipped.
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 330),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
    }

    func showRecording(mode: DictationMode, locked: Bool, anchor: CGRect? = nil) {
        let settings = AppSettings.shared
        model.captionsOn = settings.showCaptions
        // Captions sit above the bar, so with them on the bar stays at the bottom of the screen instead of covering the line you're writing.
        self.anchor = settings.indicatorPosition == .caret && !settings.showCaptions && !settings.indicatorStyle.atTop ? anchor : nil
        model.anchoredLeading = self.anchor != nil
        model.style = settings.indicatorStyle
        model.theme = settings.indicatorTheme
        model.scale = settings.indicatorScale
        model.resetForRecording()
        model.mode = mode
        model.locked = locked
        model.startedAt = Date()
        model.phase = .recording
        present()
        announce(mode == .dictation ? "Listening" : mode == .ask ? "Ask: listening" : "Command: listening")
    }

    /// The floating bar can't take focus, so VoiceOver users hear what it shows instead.
    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func showProcessing(_ label: String) {
        model.phase = .processing(label)
        present()
    }

    /// Brief confirmation (check + label) after text lands, then dissolves. With captions on, shows what was typed a little longer.
    func success(_ label: String, typed: String? = nil) {
        model.finalText = model.captionsOn ? typed?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        model.phase = .done(label)
        present()
        announce("Typed: " + label)
        scheduleHide(after: model.finalText == nil ? 0.9 : 2.6)
    }

    func flash(_ message: String, seconds: Double = 2.4, isError: Bool = true) {
        model.phase = .message(message, isError: isError)
        present()
        announce(message)
        scheduleHide(after: seconds)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        generation += 1
        let myGeneration = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            self.panel.orderOut(nil)
            // Stops the SwiftUI animations from rendering while hidden.
            self.model.phase = .hidden
            self.anchor = nil
        })
    }

    private func scheduleHide(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func present() {
        hideWork?.cancel()
        hideWork = nil
        generation += 1
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        // Only reposition when appearing, never mid-dictation, so it doesn't jump around.
        if !wasVisible { panel.setFrameOrigin(origin()) }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func origin() -> NSPoint {
        let size = panel.frame.size
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let frame = screen.visibleFrame
            // Just below the line being typed; flip above it near the bottom of the screen.
            var y = anchor.minY - 10 - Self.capsuleHeight - Self.bottomInset
            if y + Self.bottomInset < frame.minY { y = anchor.maxY + 10 - Self.bottomInset }
            // Orb centre (inset + 10 pt padding + 20 pt half-orb) lines up with the caret; keep the panel on screen.
            var x = anchor.minX - Self.leadingInset - 30
            x = min(max(x, frame.minX - Self.leadingInset + 8), frame.maxX - size.width)
            return NSPoint(x: x, y: y)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return panel.frame.origin }
        if model.style.atTop {
            // Hang just below the notch (or the menu bar on Macs without one).
            let full = screen.frame
            let menuBar = full.maxY - screen.visibleFrame.maxY
            model.topInset = max(screen.safeAreaInsets.top, menuBar) + 6
            return NSPoint(x: full.midX - size.width / 2, y: full.maxY - size.height)
        }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 6)
    }
}
