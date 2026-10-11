import AppKit
import AVFoundation
import ApplicationServices
import Combine

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone(_ done: ((Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done?(granted) }
        }
    }

    /// Shows the system prompt that adds Freshflo to the Accessibility list.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    /// What the 🌐/fn key does on its own (System Settings → Keyboard → "Press 🌐 key to").
    /// nil when the user never changed it (the macOS default differs between Macs).
    static var fnKeyAction: FnKeyAction? {
        guard let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int else { return nil }
        return FnKeyAction(rawValue: value) ?? .other
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

enum FnKeyAction: Int {
    case nothing = 0, inputSource = 1, emoji = 2, dictation = 3, other = 99

    /// What macOS does with the key, for the setup warning.
    var conflict: String? {
        switch self {
        case .nothing: return nil
        case .inputSource: return "switches your keyboard language"
        case .emoji: return "opens the Emoji & Symbols window"
        case .dictation: return "starts Apple's own dictation"
        case .other: return "does something else"
        }
    }
}

/// Polls permission state while a settings view is visible.
final class PermissionsModel: ObservableObject {
    @Published var microphone = Permissions.microphone
    @Published var accessibility = Permissions.accessibility
    @Published var speech = !LocalSpeech.needsAuthorization
    @Published var fnAction = Permissions.fnKeyAction
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        microphone = Permissions.microphone
        accessibility = Permissions.accessibility
        speech = !LocalSpeech.needsAuthorization
        fnAction = Permissions.fnKeyAction
    }
}
