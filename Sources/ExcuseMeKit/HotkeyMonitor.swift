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
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard key.keyCodes.contains(code) else {
                if isDown { onModifiersChanged?(event.flags) }
                return
            }
            let down = (event.flags.rawValue & key.flagMask) != 0
            if down, !isDown {
                isDown = true
                onPress?(event.flags)
            } else if !down, isDown {
                isDown = false
                onRelease?()
            }
        case .keyDown:
            onOtherKeyDown?(event.getIntegerValueField(.keyboardEventKeycode))
        default:
            break
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
        Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
