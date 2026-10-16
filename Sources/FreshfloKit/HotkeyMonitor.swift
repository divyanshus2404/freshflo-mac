import AppKit
import CoreGraphics

/// Watches a single modifier key system-wide via a listen-only event tap.
/// Requires the Accessibility permission; `start()` returns false until it is granted.
final class HotkeyMonitor {
    var key: HotkeyKey { didSet { isDown = false } }
    /// Called with the modifier flags held at the moment the hotkey went down.
    var onPress: ((CGEventFlags) -> Void)?
    var onRelease: (() -> Void)?
    var onOtherKeyDown: ((Int64) -> Void)?
    /// A key combination used as the talk key instead of `key` (nil = the modifier key).
    var combo: KeyCombo? { didSet { isDown = false } }
    /// Extra shortcuts; the handler returns true when it used the event (then it isn't passed to the app).
    var actions: [ShortcutAction: KeyCombo] = [:]
    var onAction: ((ShortcutAction) -> Bool)?
    /// While a shortcut is being recorded in Settings, nothing fires.
    nonisolated(unsafe) static var suspended = false
    /// Other modifiers changing while the hotkey is held (used to switch into command mode).
    var onModifiersChanged: ((CGEventFlags) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(key: HotkeyKey) {
        self.key = key
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // so a talk combo or shortcut isn't also typed into the app
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    /// Returns false to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        default: break
        }
        if Self.suspended { return true }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Flags without the talk combo's own modifiers, so ⌃⌥Space doesn't look like "talk key + Control".
        var flags = event.flags
        if let combo { flags = CGEventFlags(rawValue: flags.rawValue & ~combo.modifiers) }
        switch type {
        case .flagsChanged:
            if combo != nil {
                if isDown { onModifiersChanged?(flags) }
                return true
            }
            guard key.keyCodes.contains(code) else {
                if isDown { onModifiersChanged?(event.flags) }
                return true
            }
            let down = (event.flags.rawValue & key.flagMask) != 0
            if down, !isDown {
                isDown = true
                onPress?(event.flags)
            } else if !down, isDown {
                isDown = false
                onRelease?()
            }
            return true
        case .keyDown:
            let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let combo, combo.matches(keyCode: code, flags: event.flags.rawValue) || (isDown && code == combo.keyCode) {
                if !isDown, !repeatKey { isDown = true; onPress?(flags) }
                return false
            }
            if !repeatKey {
                for (action, c) in actions where c.matches(keyCode: code, flags: event.flags.rawValue) {
                    if onAction?(action) == true { return false }
                }
            }
            onOtherKeyDown?(code)
            return true
        case .keyUp:
            if let combo, isDown, code == combo.keyCode {
                isDown = false
                onRelease?()
                return false
            }
            return true
        default:
            return true
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        if !Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) { return nil }
    }
    return Unmanaged.passUnretained(event)
}
