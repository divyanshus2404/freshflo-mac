import AppKit
import SwiftUI

/// First-run setup, designed so anyone can go from download to a working dictation in about a minute:
/// welcome → permissions → test the key → first dictation → optional accuracy upgrade.
/// The built-in Apple engine works with no account or API key, so no step asks for one.
/// Reopen any time from the menu (Setup Guide…).
struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var permissions = PermissionsModel()
    @State private var step = 0
    @State private var keyStatus: String?
    @State private var testingKey = false
    @State private var practice = ""
    @State private var historyCountAtPractice = 0
    @State private var engineStatus = ""
    @State private var keyDown = false
    @State private var keyWorks = false
    @State private var keyMonitor: Any?
    @State private var askedAccessibility = false

    private let steps = ["Welcome", "Permissions", "Your key", "Try it", "Accuracy"]

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 26)
                .padding(.horizontal, 36)
            Group {
                switch step {
                case 0: welcome
                case 1: permissionsStep
                case 2: keyStep
                case 3: tryItStep
                default: accuracyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(.bar)
        }
        .frame(width: 620, height: 580)
        .background(Brand.backdrop)
        .tint(Brand.mint)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: step)
        .onAppear {
            permissions.startPolling()
            refreshEngine()
        }
        .onDisappear {
            permissions.stopPolling()
            stopKeyTest()
        }
        .onChange(of: step) { _, new in new == 2 ? startKeyTest() : stopKeyTest() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Brand.mint : Color.secondary.opacity(0.18))
                    .frame(height: 4)
            }
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
                    .shadow(color: Brand.mint.opacity(0.25), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Say it messy.").font(.system(size: 38, weight: .regular, design: .serif))
                    Text("Send it fresh.").font(.system(size: 38, weight: .regular, design: .serif)).italic().foregroundStyle(Brand.mintText)
                }
            }
            Text("Freshflo turns your voice into clean, polished text in any app. No typing, no account, free.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                howRow(1, key: settings.hotkey.shortLabel, "Hold your talk key", "in any app where you can type")
                howRow(2, key: nil, "Talk naturally", "ums, restarts and “no wait” are fine")
                howRow(3, key: nil, "Let go", "clean text appears where your cursor is")
            }
            .padding(.top, 4)
        }
    }

    private func howRow(_ n: Int, key: String?, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Text("\(n)").font(.system(.callout, design: .rounded).weight(.bold)).foregroundStyle(Brand.mintText)
                .frame(width: 28, height: 28).background(Circle().fill(Brand.mint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let key { Keycap(label: key, small: true) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Permissions

    private var needsSpeech: Bool { settings.provider == .local && LocalSpeech.needsAuthorization }
    private var permissionsDone: Bool {
        permissions.accessibility && permissions.microphone == .authorized && (permissions.speech || settings.provider != .local)
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(needsSpeech || !permissions.speech && settings.provider == .local ? "Allow three things" : "Allow two things",
                  "macOS asks once. Freshflo only listens while you hold the key, and never reads password fields.")
            permissionCard(icon: "mic.fill", name: "Microphone", detail: "To hear you while you hold the key.",
                           granted: permissions.microphone == .authorized) {
                if permissions.microphone == .notDetermined {
                    Permissions.requestMicrophone { _ in permissions.refresh() }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            }
            permissionCard(icon: "keyboard", name: "Accessibility", detail: "To notice your key in any app and type the text for you.",
                           granted: permissions.accessibility) {
                askedAccessibility = true
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if settings.provider == .local, !permissions.speech || LocalSpeech.needsAuthorization {
                permissionCard(icon: "waveform", name: "Speech Recognition", detail: "For the free built-in engine on this version of macOS.",
                               granted: permissions.speech) {
                    Task { @MainActor in
                        if await LocalSpeech.requestAuthorization() == false { Permissions.openSpeechSettings() }
                        permissions.refresh()
                    }
                }
            }
            if askedAccessibility, !permissions.accessibility {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In the window that opened:").font(.callout.weight(.semibold))
                    Text("1. Turn on the switch next to **Freshflo**.  2. Come back here. This page updates by itself.")
                    Text("Don't see Freshflo? Click **+**, open Applications and choose Freshflo.").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.mint.opacity(0.08)))
            }
        }
    }

    private func permissionCard(icon: String, name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(granted ? Brand.mint : .secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.mint).font(.callout.weight(.semibold))
            } else {
                Button("Allow", action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(granted ? 0.03 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(granted ? Brand.mint.opacity(0.35) : Color.primary.opacity(0.08)))
        .animation(.easeOut(duration: 0.25), value: granted)
    }

    // MARK: Key

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your talk key", "Hold it to talk, let go to insert. Tap it once for hands-free.")
            HStack(spacing: 22) {
                Keycap(label: settings.hotkey.shortLabel, pressed: keyDown)
                VStack(alignment: .leading, spacing: 6) {
                    if keyWorks {
                        Label("Works. You're all set.", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Brand.mint)
                    } else {
                        Text("Press it now to check.").font(.headline)
                    }
                    Text("No \(settings.hotkey == .fn ? "fn key on your keyboard" : "luck")? Pick another key below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            HStack(spacing: 8) {
                ForEach(HotkeyKey.allCases) { key in
                    Button {
                        settings.hotkey = key
                        keyWorks = false
                    } label: {
                        Text(key.shortLabel).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(settings.hotkey == key ? Brand.mint.opacity(0.18) : Color.primary.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(settings.hotkey == key ? Brand.mint : Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if settings.hotkey == .fn {
                fnAdvice
            }
            Text("Hold \(settings.hotkey.shortLabel) + Control to edit by voice (\u{201C}make that shorter\u{201D}), \(settings.hotkey.shortLabel) + Shift to ask a question.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fnAdvice: some View {
        if let action = permissions.fnAction, action == .nothing {
            Label("Your 🌐 fn key is free for Freshflo.", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(Brand.mint)
        } else {
            let conflict = permissions.fnAction?.conflict
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: conflict == nil ? "lightbulb" : "exclamationmark.triangle.fill")
                    .foregroundStyle(conflict == nil ? Brand.mint : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.map { "Right now the 🌐 key \($0)." } ?? "If an emoji window pops up when you let go of fn:")
                        .font(.callout.weight(.semibold))
                    Text("In Keyboard settings, set “Press 🌐 key to” → **Do Nothing**.").font(.callout)
                }
                Spacer()
                Button("Open Keyboard Settings") { Permissions.openKeyboardSettings() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill((conflict == nil ? Brand.mint : Color.orange).opacity(0.09)))
        }
    }

    private func startKeyTest() {
        DictationController.paused = true
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let down: Bool
            switch settings.hotkey {
            case .fn: down = event.modifierFlags.contains(.function) && (event.keyCode == 63 || event.keyCode == 179)
            case .rightOption: down = event.keyCode == 61 && event.modifierFlags.contains(.option)
            case .rightCommand: down = event.keyCode == 54 && event.modifierFlags.contains(.command)
            case .rightControl: down = event.keyCode == 62 && event.modifierFlags.contains(.control)
            }
            if settings.hotkey.keyCodes.contains(Int64(event.keyCode)) {
                withAnimation(.easeOut(duration: 0.12)) { keyDown = down }
                if down { withAnimation { keyWorks = true } }
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func stopKeyTest() {
        stopKeyMonitor()
        DictationController.paused = false
        keyDown = false
    }

    // MARK: Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if history.items.count > historyCountAtPractice, let last = history.items.first {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Brand.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("It works.").font(.system(size: 30, design: .serif))
                        Text("That's all there is to it. Freshflo lives in your menu bar.").foregroundStyle(.secondary)
                    }
                }
                Text("\u{201C}\(last.text)\u{201D}")
                    .font(.system(.title3, design: .serif))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.mint.opacity(0.08)))
            } else {
                title("Try it now", "")
                HStack(spacing: 6) {
                    Text("Click in the box, hold")
                    Keycap(label: settings.hotkey.shortLabel, small: true)
                    Text("and say:")
                }
                .font(.title3)
                Text("\u{201C}um, hey, this is my first dictation, no wait, my first test\u{201D}")
                    .font(.system(.title3, design: .serif)).italic().foregroundStyle(Brand.mintText)
                Text("Then let go.").font(.title3)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
                    .frame(height: 110)
                if practice.isEmpty {
                    Text("Click here first…").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                }
            }
            if !permissionsDone {
                Label("Some permissions are still missing, so this won't work yet. Go back one step.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onAppear { historyCountAtPractice = history.items.count }
    }

    // MARK: Accuracy (optional)

    private var accuracyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Want even better accuracy?", "Optional. Freshflo already works. This makes names, accents and Hinglish noticeably better.")
            engineCard(selected: settings.provider == .local, icon: "applelogo", name: "Built-in (Apple)",
                       detail: engineStatus.isEmpty ? "Free, no account." : "Free, no account. \(engineStatus).") {
                settings.provider = .local
                refreshEngine()
            }
            engineCard(selected: settings.provider == .groq, icon: "bolt.fill", name: "Groq Whisper (recommended)",
                       detail: "The most accurate, about 0.3 s per dictation. Needs a free key, takes a minute.") {
                settings.provider = .groq
            }
            if settings.provider == .groq {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("1.")
                        Link("Get your free key at console.groq.com →", destination: URL(string: "https://console.groq.com/keys")!)
                    }
                    HStack(spacing: 8) {
                        Text("2.")
                        SecureField("", text: $settings.apiKey, prompt: Text("Paste it here (starts with gsk_)"))
                            .textFieldStyle(.roundedBorder)
                        Button(testingKey ? "Checking…" : "Check") { testKey() }.disabled(testingKey || settings.apiKey.isEmpty)
                    }
                    if let keyStatus {
                        Text(keyStatus).font(.callout).foregroundStyle(keyStatus.hasPrefix("✓") ? Brand.mint : .red)
                    }
                }
                .font(.callout)
                .padding(.leading, 6)
            }
        }
    }

    private func engineCard(selected: Bool, icon: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 30).foregroundStyle(selected ? Brand.mint : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? Brand.mint : .secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Brand.mint.opacity(0.08) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Brand.mint : Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }.controlSize(.large)
            }
            Spacer()
            switch step {
            case 0:
                Button("Set up in a minute") { step = 1 }.keyboardShortcut(.defaultAction).controlSize(.large)
            case 1:
                if !permissionsDone { Button("Skip for now") { step += 1 }.buttonStyle(.borderless) }
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large).disabled(!permissionsDone)
            case 3:
                Button(history.items.count > historyCountAtPractice ? "Continue" : "Skip") { step += 1 }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            case 4:
                Button(settings.provider == .groq && !settings.canUseCloud ? "Use built-in for now" : "Finish") {
                    if settings.provider == .groq, !settings.canUseCloud { settings.provider = .local }
                    onFinish()
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
            default:
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.system(size: 30, weight: .regular, design: .serif))
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func testKey() {
        testingKey = true
        let endpoint = settings.endpoint
        Task { @MainActor in
            do {
                try await OpenAICompatible.verify(endpoint)
                keyStatus = "✓ Key works. Freshflo will use Groq from now on."
            } catch {
                keyStatus = error.localizedDescription
            }
            testingKey = false
        }
    }

    private func refreshEngine() {
        let language = settings.language
        Task { @MainActor in
            let status = await LocalSpeech.status(language: language)
            engineStatus = status == "Ready" ? "Runs on this Mac" : status.replacingOccurrences(of: "Ready (uses Apple's servers)", with: "Uses Apple's speech servers")
        }
    }
}

/// Brand colours shared by setup and other windows.
enum Brand {
    static let mint = Color(red: 0.055, green: 0.62, blue: 0.47)
    static let mintText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.33, green: 0.89, blue: 0.72, alpha: 1) : NSColor(red: 0.03, green: 0.48, blue: 0.36, alpha: 1)
    })
    static var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [mint.opacity(0.12), .clear], center: .topLeading, startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.42, green: 0.65, blue: 1).opacity(0.08), .clear], center: .topTrailing, startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// A keyboard key drawn like a real keycap; lights up mint while pressed.
struct Keycap: View {
    var label: String
    var pressed = false
    var small = false

    var body: some View {
        Text(label)
            .font(.system(size: small ? 12 : 30, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .frame(minWidth: small ? 26 : 96, minHeight: small ? 22 : 82)
            .padding(.horizontal, small ? 6 : 10)
            .background(
                RoundedRectangle(cornerRadius: small ? 6 : 16)
                    .fill(pressed ? Brand.mint : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(pressed ? 0.05 : 0.18), radius: 0, y: pressed ? 1 : (small ? 2 : 5))
            )
            .overlay(RoundedRectangle(cornerRadius: small ? 6 : 16).strokeBorder(Color.primary.opacity(0.14)))
            .offset(y: pressed ? (small ? 1 : 4) : 0)
            .shadow(color: pressed ? Brand.mint.opacity(0.5) : .clear, radius: 14)
    }
}
