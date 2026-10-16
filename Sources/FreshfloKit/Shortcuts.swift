import AppKit
import SwiftUI

/// A key plus modifiers (⌃⌥⇧⌘), e.g. ⌃⌥Space or F13. Stored with its display label.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: Int64
    var modifiers: UInt64          // device-independent CGEventFlags bits (command/option/control/shift)
    var key: String                // "Space", "D", "F13"…

    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    static let escape = KeyCombo(keyCode: 53, modifiers: 0, key: "Esc")

    var label: String {
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s + key
    }

    func matches(keyCode code: Int64, flags: UInt64) -> Bool {
        code == keyCode && (flags & Self.modifierMask) == modifiers
    }

    static let functionKeys: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let named: [Int64: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 50: "`",
    ]

    static func keyName(code: Int64, characters: String?) -> String {
        if let f = functionKeys[code] { return f }
        if let n = named[code] { return n }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "Key \(code)" : c
    }

    /// Why this combo can't be used (nil = fine). Plain letters and the everyday ⌘ shortcuts would break typing.
    func problem(allowBare: Bool) -> String? {
        let mods = modifiers
        let isF = Self.functionKeys[keyCode] != nil
        if mods == 0, !isF, !allowBare { return "Add a modifier (⌃ ⌥ ⇧ ⌘), or use an F-key" }
        if mods == CGEventFlags.maskShift.rawValue, !isF { return "Shift alone would block capital letters" }
        if mods == CGEventFlags.maskCommand.rawValue || mods == CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
           ["Q", "W", "C", "V", "X", "Z", "A", "S", "T", "N", "O", "P", "F", "Tab", "Space", "`"].contains(key) {
            return "\(label) is a standard Mac shortcut"
        }
        if keyCode == 48, mods == CGEventFlags.maskCommand.rawValue { return "⌘Tab switches apps" }
        return nil
    }
}

/// How the talk key behaves.
enum TalkMode: String, CaseIterable, Identifiable {
    case holdOrTap, hold, toggle, doubleTap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .holdOrTap: return "Hold to talk, tap for hands-free"
        case .hold: return "Hold to talk only"
        case .toggle: return "Press to start, press again to stop"
        case .doubleTap: return "Hold to talk, double-tap for hands-free"
        }
    }
    func hint(_ key: String) -> String {
        switch self {
        case .holdOrTap: return "Hold \(key) to dictate · tap for hands-free"
        case .hold: return "Hold \(key) to dictate"
        case .toggle: return "Press \(key) to start and stop dictating"
        case .doubleTap: return "Hold \(key) to dictate · double-tap for hands-free"
        }
    }
}

/// Extra global shortcuts. None are set by default except Cancel (Esc, only while dictating).
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case cancel, handsFree, pasteLast, meeting, scratchpad
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cancel: return "Cancel dictation"
        case .handsFree: return "Start or stop hands-free"
        case .pasteLast: return "Paste last dictation"
        case .meeting: return "Start or stop meeting notes"
        case .scratchpad: return "Open Scratchpad"
        }
    }
    var defaultCombo: KeyCombo? { self == .cancel ? .escape : nil }
}

/// Pure decisions for the talk key, kept separate so they can be checked without a keyboard.
struct TalkKeyLogic {
    /// Holding shorter than this counts as a tap.
    static let tapThreshold: TimeInterval = 0.3
    /// Two taps closer than this are a double-tap.
    static let doubleTapWindow: TimeInterval = 0.45

    enum Release: Equatable { case finish, lock, cancelQuietly, ignore }

    static func onRelease(mode: TalkMode, held: TimeInterval, locked: Bool) -> Release {
        if locked { return .ignore }
        let tap = held < tapThreshold
        switch mode {
        case .holdOrTap: return tap ? .lock : .finish
        case .hold: return tap ? .cancelQuietly : .finish
        case .toggle: return .ignore
        case .doubleTap: return tap ? .cancelQuietly : .finish
        }
    }

    /// Should a new press start hands-free straight away?
    static func startsLocked(mode: TalkMode, lastTap: Date?, now: Date = Date()) -> Bool {
        switch mode {
        case .toggle: return true
        case .doubleTap: return lastTap.map { now.timeIntervalSince($0) < doubleTapWindow } ?? false
        default: return false
        }
    }
}

// MARK: - Recorder control

/// Click, then press the shortcut. Delete clears it, Esc stops recording (except when recording Cancel itself).
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var allowBare = false
    var taken: (KeyCombo) -> String? = { _ in nil }
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (combo?.label ?? "Record shortcut"))
                    .font(.system(.body, design: .rounded).weight(combo == nil ? .regular : .semibold))
                    .foregroundStyle(recording ? Color.accentColor : combo == nil ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            if combo != nil, !recording {
                Button { combo = nil; error = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        error = nil
        recording = true
        HotkeyMonitor.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = Int64(e.keyCode)
            let mods = UInt64(e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            if mods == 0, code == 53, !allowBare { stop(); return nil }
            if mods == 0, code == 51 { combo = nil; stop(); return nil }
            let c = KeyCombo(keyCode: code, modifiers: mods, key: KeyCombo.keyName(code: code, characters: e.charactersIgnoringModifiers))
            if let p = c.problem(allowBare: allowBare) ?? taken(c) { error = p; NSSound.beep(); return nil }
            combo = c
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        HotkeyMonitor.suspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
