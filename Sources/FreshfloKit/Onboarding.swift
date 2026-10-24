import AppKit
import ServiceManagement
import SwiftUI

/// First-run setup assistant: anyone goes from download to a working dictation in about a minute.
/// Welcome (animated demo) → permissions (auto-advances) → test the talk key → first dictation → finish
/// (shortcut cheat sheet, open at login, optional accuracy upgrade). The built-in Apple engine needs no account or key.
/// Always shown in the light brand look. Reopen from the menu (Setup Guide…).
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
    @State private var openAtLogin = true
    @State private var showUpgrade = false
    @State private var celebrate = false
    /// Fetch the better offline model in the background after setup (only if it isn't there yet).
    @State private var downloadWhisper = !OnDeviceWhisper.isDownloaded

    private let steps: [(title: String, icon: String)] = [
        ("Welcome", "hand.wave"), ("Permissions", "lock.shield"), ("Talk key", "keyboard"),
        ("Your languages", "globe"), ("First dictation", "waveform"), ("Finish", "flag.checkered"),
    ]

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: permissionsStep
                    case 2: keyStep
                    case 3: languagesStep
                    case 4: tryItStep
                    default: finishStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.top, 34)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                footer
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.7))
                    .overlay(alignment: .top) { Divider() }
            }
            .background(Brand.backdrop)
        }
        .frame(width: 820, height: 580)
        .environment(\.colorScheme, .light)
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
        .onChange(of: permissionsDone) { _, done in
            // Everything granted while on this step: move on by itself.
            guard done, step == 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if step == 1 { step = 2 } }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                (Text("freshflo") + Text(".").foregroundColor(Brand.mint))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .padding(.bottom, 30)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    let done = i < step, current = i == step
                    HStack(spacing: 11) {
                        ZStack {
                            Circle().fill(done ? Brand.mint : (current ? Color.white : Color.black.opacity(0.05)))
                            Circle().strokeBorder(current ? Brand.mint : Color.clear, lineWidth: 2)
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(i + 1)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(current ? Brand.mint : Color.secondary)
                            }
                        }
                        .frame(width: 24, height: 24)
                        Text(steps[i].title)
                            .font(.system(size: 13.5, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Color.primary : (done ? Color.primary.opacity(0.75) : Color.secondary))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(current ? Color.white.opacity(0.8) : .clear))
                    .shadow(color: current ? Color.black.opacity(0.06) : .clear, radius: 6, y: 2)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("About a minute", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                Label("Only listens while you hold the key", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 236)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [Brand.mint.opacity(0.13), Color(red: 0.42, green: 0.65, blue: 1).opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(Color(red: 0.97, green: 0.985, blue: 0.98))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1) }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Say it messy.").font(.system(size: 40, weight: .regular, design: .serif))
                Text("Send it fresh.").font(.system(size: 40, weight: .regular, design: .serif)).italic().foregroundStyle(Brand.mintText)
            }
            Text("Talk the way you think. Freshflo turns it into clean, polished text in any app. Free, with no account.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DemoReplay()
            HStack(spacing: 10) {
                stepChip("1", key: settings.hotkey.shortLabel, "Hold")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                stepChip("2", key: nil, "Talk")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                stepChip("3", key: nil, "Let go")
            }
        }
    }

    private func stepChip(_ n: String, key: String?, _ text: String) -> some View {
        HStack(spacing: 7) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Brand.mintText)
                .frame(width: 20, height: 20).background(Circle().fill(Brand.mint.opacity(0.15)))
            Text(text).font(.callout.weight(.medium))
            if let key { Keycap(label: key, small: true) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.07)))
    }

    // MARK: Permissions

    private var permissionsDone: Bool {
        permissions.accessibility && permissions.microphone == .authorized && (permissions.speech || settings.provider.transcribesInCloud)
    }
    private var showsSpeechCard: Bool { !settings.provider.transcribesInCloud && LocalSpeech.needsAuthorization || !settings.provider.transcribesInCloud && !permissions.speech }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(showsSpeechCard ? "Allow three things" : "Allow two things",
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
            if showsSpeechCard {
                permissionCard(icon: "waveform", name: "Speech Recognition", detail: "For the free built-in engine on this version of macOS.",
                               granted: permissions.speech) {
                    Task { @MainActor in
                        if await LocalSpeech.requestAuthorization() == false { Permissions.openSpeechSettings() }
                        permissions.refresh()
                    }
                }
            }
            if permissionsDone {
                Label("All set. Moving on…", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Brand.mint)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if !permissions.accessibility {
                accessibilityGuide
            }
        }
        .animation(.easeOut(duration: 0.3), value: permissionsDone)
    }

    /// A picture of the exact row to switch on, so nobody hunts through System Settings.
    private var accessibilityGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(askedAccessibility ? "In the System Settings window that opened, switch this on:"
                                    : "After you click Allow, System Settings opens. Switch this on:").font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("Freshflo").font(.callout)
                Spacer()
                ZStack(alignment: .trailing) {
                    Capsule().fill(Brand.mint).frame(width: 38, height: 22)
                    Circle().fill(.white).frame(width: 18, height: 18).padding(.trailing, 2).shadow(radius: 1, y: 1)
                }
                Image(systemName: "hand.point.left.fill").foregroundStyle(.orange)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.08)))
            Text("Not in the list? Click **+** at the bottom, choose Applications → Freshflo. This page updates by itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.mint.opacity(0.07)))
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
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(granted ? 0.6 : 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(granted ? Brand.mint.opacity(0.45) : Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(granted ? 0 : 0.04), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.25), value: granted)
    }

    // MARK: Talk key

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your talk key", "Hold it to talk, let go to insert. Tap it once for hands-free.")
            HStack(spacing: 22) {
                Keycap(label: settings.hotkey.shortLabel, pressed: keyDown)
                VStack(alignment: .leading, spacing: 6) {
                    if keyWorks {
                        Label("It works.", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Brand.mint)
                            .transition(.scale.combined(with: .opacity))
                        Text("That's the key you'll hold to talk.").foregroundStyle(.secondary)
                    } else {
                        Text("Press it now to check.").font(.title3.weight(.semibold))
                        Text(settings.hotkey == .fn ? "No fn key on your keyboard? Pick Right ⌥ below." : "Pick a different key below any time.")
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: keyWorks)
            }
            .padding(.vertical, 6)
            HStack(spacing: 8) {
                ForEach(HotkeyKey.allCases) { key in
                    Button {
                        settings.hotkey = key
                        keyWorks = false
                    } label: {
                        Text(key.shortLabel).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(settings.hotkey == key ? Brand.mint.opacity(0.18) : Color.white.opacity(0.8)))
                            .overlay(Capsule().strokeBorder(settings.hotkey == key ? Brand.mint : Color.black.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if settings.hotkey == .fn { fnAdvice }
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
            let key = settings.hotkey
            let down = key.keyCodes.contains(Int64(event.keyCode)) && (UInt64(event.modifierFlags.rawValue) & key.flagMask) != 0
            if settings.hotkey.keyCodes.contains(Int64(event.keyCode)) {
                withAnimation(.easeOut(duration: 0.12)) { keyDown = down }
                if down { keyWorks = true }
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

    // MARK: First dictation

    private var practiced: Bool { history.items.count > historyCountAtPractice }

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if practiced, let last = history.items.first {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Brand.mint)
                        .symbolEffect(.bounce, value: celebrate)
                        .shadow(color: Brand.mint.opacity(0.4), radius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You just dictated.").font(.system(size: 32, design: .serif))
                        Text(last.latencyMs.map { "Typed \(String(format: "%.2f", Double($0) / 1000)) s after you let go." } ?? "That's all there is to it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear { celebrate.toggle() }
                Text("\u{201C}\(last.text)\u{201D}")
                    .font(.system(.title3, design: .serif))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.mint.opacity(0.4)))
                Text("Try it once more in the box, or continue.").font(.callout).foregroundStyle(.secondary)
            } else {
                title("Your first dictation", "")
                HStack(spacing: 6) {
                    Text("Click in the box, hold")
                    Keycap(label: settings.hotkey.shortLabel, small: true)
                    Text("and say:")
                }
                .font(.title3)
                Text("\u{201C}um, hey, this is my first dictation, no wait, my first test\u{201D}")
                    .font(.system(.title3, design: .serif)).italic().foregroundStyle(Brand.mintText)
                Text("Then let go and watch the ums disappear.").font(.title3)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.1)))
                    .frame(height: practiced ? 70 : 110)
                if practice.isEmpty {
                    Text("Click here first…").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                }
            }
            if !permissionsDone {
                Label("Some permissions are still missing, so this won't work yet. Go back to Permissions.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onAppear { historyCountAtPractice = history.items.count }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: practiced)
    }

    // MARK: Languages

    /// The languages people dictate in most, shown as chips; the rest are one menu away.
    private static let commonLanguages = ["en", "hi", "bn", "mr", "ta", "te", "gu", "kn", "ml", "pa", "ur", "es", "fr", "de"]

    private var languagesStep: some View {
        let spoken = settings.spokenLanguages
        let name = { (code: String) in Languages.spoken.first { $0.code == code }?.name ?? code }
        let mixesHindi = spoken.contains("hi") && spoken.contains("en")
        return VStack(alignment: .leading, spacing: 16) {
            title("Which languages do you speak?", "Include the ones you mix: Hinglish is Hindi + English. Freshflo listens for these only. Change them anytime, or press ⌃⌥L while you work.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Self.commonLanguages + spoken.filter { !Self.commonLanguages.contains($0) }, id: \.self) { code in
                    let on = spoken.contains(code)
                    Button { toggleSpoken(code) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Brand.mint : Color.secondary)
                            Text(name(code)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Brand.mint.opacity(0.14) : Color.white.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Brand.mint : Color.black.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Menu("More…") {
                    ForEach(Languages.spoken.filter { !$0.code.isEmpty && !Self.commonLanguages.contains($0.code) }, id: \.code) { lang in
                        Button { toggleSpoken(lang.code) } label: {
                            if spoken.contains(lang.code) { Label(lang.name, systemImage: "checkmark") } else { Text(lang.name) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Write my words in").font(.headline)
                ForEach(writeChoices(spoken), id: \.tag) { choice in
                    let on = settings.outputLanguage == choice.tag
                    Button { settings.outputLanguage = choice.tag } label: {
                        HStack(spacing: 8) {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Brand.mint : Color.secondary)
                            Text(choice.label)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if mixesHindi {
                    example(settings.outputLanguage)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
        }
    }

    private func writeChoices(_ spoken: [String]) -> [(tag: String, label: String)] {
        var list: [(tag: String, label: String)] = [("", "The language I speak")]
        if spoken.count > 1 || spoken.first != "en" { list.append(("English", "English, always")) }
        if spoken.contains("hi") { list += [("Hindi", "Hindi (हिन्दी)"), ("Hinglish (Hindi in Latin letters)", "Hinglish (Roman letters)")] }
        if !list.contains(where: { $0.tag == settings.outputLanguage }) { list.append((settings.outputLanguage, settings.outputLanguage)) }
        return list
    }

    /// What the choice means, shown with a Hinglish sentence.
    @ViewBuilder private func example(_ writeIn: String) -> some View {
        let said = "“kal meeting hai, deck ready rakhna”"
        let typed: String = switch writeIn {
        case "English": "“There's a meeting tomorrow, keep the deck ready.”"
        case "Hindi": "“कल मीटिंग है, डेक तैयार रखना।”"
        case "": "“Kal meeting hai, deck ready rakhna.”"
        default: "“Kal meeting hai, deck ready rakhna.”"
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(Brand.mint)
            (Text("You say ").foregroundColor(.secondary) + Text(said) + Text("  →  Freshflo types ").foregroundColor(.secondary) + Text(typed).bold())
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleSpoken(_ code: String) {
        if let i = settings.spokenLanguages.firstIndex(of: code) {
            settings.spokenLanguages.remove(at: i)
        } else {
            settings.spokenLanguages.append(code)
        }
        // Detection picks among your languages each time; a single pinned language would block the others.
        if !settings.language.isEmpty, settings.spokenLanguages.count != 1 || settings.spokenLanguages.first != settings.language {
            settings.language = ""
        }
        // Writing in a language you no longer speak (other than English) makes no sense: fall back to as spoken.
        if settings.outputLanguage == "Hindi" || settings.outputLanguage.hasPrefix("Hinglish"), !settings.spokenLanguages.contains("hi") {
            settings.outputLanguage = ""
        }
    }

    // MARK: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("You're all set", "Three keys to remember. Freshflo lives in your menu bar.")
            VStack(spacing: 8) {
                cheat(keys: [settings.hotkey.shortLabel], "Hold to dictate", "Tap once for hands-free. Esc cancels.", color: Brand.mint)
                cheat(keys: [settings.hotkey.shortLabel, "control"], "Edit by voice", "“make that shorter”, “scratch that”", color: Color(red: 0.44, green: 0.31, blue: 0.88))
                cheat(keys: [settings.hotkey.shortLabel, "shift"], "Ask anything", "“remind me to call Rahul at 5”", color: Color(red: 0.18, green: 0.48, blue: 0.88))
            }
            Toggle(isOn: $openAtLogin) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Freshflo when I log in").font(.headline)
                    Text("So it's ready whenever you want to talk.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
            if !OnDeviceWhisper.isDownloaded && !(settings.provider == .groq && settings.canUseCloud) {
                Toggle(isOn: $downloadWhisper) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Get sharper offline accuracy").font(.headline)
                        Text("Downloads Whisper (\(OnDeviceWhisper.sizeLabel)) in the background. You can dictate right away meanwhile.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
            }
            Toggle(isOn: $settings.shareUsage) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Help improve Freshflo").font(.headline)
                    Text("Share anonymous daily counts and crash reports. Never your words.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
            DisclosureGroup(isExpanded: $showUpgrade) {
                upgrade.padding(.top, 8)
            } label: {
                Text(settings.provider == .groq && settings.canUseCloud ? "Accuracy: Groq Whisper ✓" : "Want sharper accuracy for names and accents? (optional)")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func cheat(keys: [String], _ title: String, _ detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            HStack(spacing: 4) {
                ForEach(keys.indices, id: \.self) { i in
                    if i > 0 { Text("+").foregroundStyle(.tertiary).font(.caption) }
                    Keycap(label: keys[i], small: true)
                }
            }
            .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.06)))
    }

    private var upgrade: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groq Whisper is the most accurate engine (about 0.3 s per dictation). The key is free and takes a minute.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("1.")
                Link("Get your free key at console.groq.com →", destination: URL(string: "https://console.groq.com/keys")!)
            }
            HStack(spacing: 8) {
                Text("2.")
                SecureField("", text: Binding(get: { settings.provider == .groq ? settings.apiKey : "" }, set: { new in
                    if settings.provider != .groq { settings.provider = .groq }
                    settings.apiKey = new
                }), prompt: Text("Paste it here (starts with gsk_)"))
                .textFieldStyle(.roundedBorder)
                Button(testingKey ? "Checking…" : "Check") { testKey() }.disabled(testingKey || settings.apiKey.isEmpty || settings.provider != .groq)
            }
            if let keyStatus {
                Text(keyStatus).font(.callout).foregroundStyle(keyStatus.hasPrefix("✓") ? Brand.mint : .red)
            }
            if settings.provider == .groq {
                Button("Use the built-in engine instead") { settings.provider = .local; keyStatus = nil }.buttonStyle(.link).font(.callout)
            }
        }
        .font(.callout)
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
                Button("Set up in a minute") { step = 1 }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            case 1:
                if !permissionsDone { Button("Skip for now") { step += 1 }.buttonStyle(.borderless) }
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent).disabled(!permissionsDone)
            case 3:
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(settings.spokenLanguages.isEmpty)
            case 4:
                Button(practiced ? "Continue" : "Skip") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            case 5:
                Button("Start using Freshflo") { finish() }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            default:
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
            }
        }
    }

    private func finish() {
        // A Groq choice without a working key would leave dictation broken; fall back to the built-in engine.
        if settings.provider == .groq, !settings.canUseCloud { settings.provider = .local }
        if openAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if downloadWhisper, !OnDeviceWhisper.isDownloaded {
            settings.useOnDeviceWhisper = true
            Task.detached(priority: .utility) { try? await OnDeviceWhisper.download { _ in } }
        }
        Insights.milestone("setup_finished")
        onFinish()
    }

    // MARK: Pieces

    @ViewBuilder private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(heading)).font(.system(size: 32, weight: .regular, design: .serif))
            if !detail.isEmpty {
                Text(LocalizedStringKey(detail)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        Task { @MainActor in engineStatus = await LocalSpeech.status(language: language) }
    }
}

/// The welcome screen's looping demo: rambling words stream into the pill, the mess is struck out,
/// and the clean sentence lands. It explains the product without a paragraph.
struct DemoReplay: View {
    private let raw = ["um", "so", "let's", "meet", "on", "Tuesday,", "no", "wait,", "Wednesday", "at", "five"]
    private let dropped: Set<Int> = [0, 1, 5, 6, 7]
    private let clean = "Let's meet on Wednesday at 5."
    private let cycle = 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            let shown = min(raw.count, Int(t / 0.28) + 1)
            let listening = t < 3.3
            let struck = t > 3.5
            let done = t > 4.3
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(Brand.mint).frame(width: 7, height: 7).shadow(color: Brand.mint, radius: 4)
                    HStack(spacing: 2.5) {
                        ForEach(0..<11, id: \.self) { i in
                            let wave = abs(sin(t * 7 + Double(i) * 0.9)) * sin(Double(i + 1) / 12 * .pi)
                            Capsule().fill(Brand.mint).frame(width: 3, height: listening ? 4 + 16 * wave : 3)
                        }
                    }
                    .frame(height: 22)
                    Text(done ? "Inserted · 0.31 s" : (listening ? "Listening…" : "Polishing…"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Color(red: 0.06, green: 0.1, blue: 0.09)))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                raw.indices.reduce(Text("")) { text, i in
                    guard i < shown else { return text }
                    let gone = struck && dropped.contains(i)
                    return text + Text(raw[i] + " ")
                        .strikethrough(gone, color: .red)
                        .foregroundColor(gone ? Color.red.opacity(0.75) : .secondary)
                        .italic()
                }
                .font(.system(size: 16))
                .frame(height: 22, alignment: .leading)

                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(Brand.mint)
                    Text(clean).font(.system(size: 20, design: .serif))
                }
                .opacity(done ? 1 : 0)
                .offset(y: done ? 0 : 6)
                .animation(.easeOut(duration: 0.4), value: done)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
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
            Color(red: 0.985, green: 0.992, blue: 0.99)
            RadialGradient(colors: [mint.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 460)
            RadialGradient(colors: [Color(red: 0.42, green: 0.65, blue: 1).opacity(0.06), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 380)
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
                    .fill(pressed ? Brand.mint : Color.white)
                    .shadow(color: .black.opacity(pressed ? 0.05 : 0.18), radius: 0, y: pressed ? 1 : (small ? 2 : 5))
            )
            .overlay(RoundedRectangle(cornerRadius: small ? 6 : 16).strokeBorder(Color.black.opacity(0.14)))
            .offset(y: pressed ? (small ? 1 : 4) : 0)
            .shadow(color: pressed ? Brand.mint.opacity(0.5) : .clear, radius: 14)
    }
}
