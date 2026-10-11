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

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Polls permission state while a settings view is visible.
final class PermissionsModel: ObservableObject {
    @Published var microphone = Permissions.microphone
    @Published var accessibility = Permissions.accessibility
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
    }
}
