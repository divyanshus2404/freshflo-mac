import AppKit
import ApplicationServices

enum TextInserter {
    /// Pastes `text` into the focused field, then restores the user's clipboard.
    /// Returns false (leaving the text on the clipboard) when Accessibility access is missing.
    /// `verify` runs shortly after pasting; returning false keeps the text on the clipboard and calls `onFailed`.
    @discardableResult
    static func insert(_ text: String, verify: (() -> Bool)? = nil, onFailed: (() -> Void)? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Lets clipboard managers know this entry is temporary.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])

        guard AXIsProcessTrusted() else { return false }
        let ourChange = pasteboard.changeCount
        postShortcut(key: 9) // ⌘V

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let verify, !verify() {
                // Paste didn't land (some apps block it): leave the text on the clipboard for a manual ⌘V.
                onFailed?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard pasteboard.changeCount == ourChange else { return }
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    /// Reads the selection by sending ⌘C, for apps that don't expose it through Accessibility.
    @MainActor
    static func copySelection() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        postShortcut(key: 8) // ⌘C
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        return text
    }

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restore(_ saved: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.writeObjects(saved.map { pairs in
            let restored = NSPasteboardItem()
            for (type, data) in pairs { restored.setData(data, forType: type) }
            return restored
        })
    }

    /// Presses Delete once (removes a selection) or `count` times.
    static func pressDelete(count: Int = 1) {
        for _ in 0..<count { postShortcut(key: 51, flags: []) }
    }

    private static func postShortcut(key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
