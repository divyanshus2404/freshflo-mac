import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A theme you made: one accent per mode, stored as hex so it can be shared as a small file.
struct UserTheme: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var accent: String      // dictation
    var command: String     // Command mode
    var ask: String         // Ask mode

    static let starter = UserTheme(name: "My theme", accent: "#FF6FB5", command: "#B894FF", ask: "#6BAAFF")

    /// Ready-made starting points for the editor.
    static let presets: [UserTheme] = [
        UserTheme(name: "Bubblegum", accent: "#FF6FB5", command: "#B894FF", ask: "#6BAAFF"),
        UserTheme(name: "Ocean", accent: "#2EC4F1", command: "#7C8CFF", ask: "#3DE0C4"),
        UserTheme(name: "Saffron", accent: "#FFA62B", command: "#FF6B6B", ask: "#4ECDC4"),
        UserTheme(name: "Forest", accent: "#7BD389", command: "#C3A6FF", ask: "#76B9F0"),
        UserTheme(name: "Ruby", accent: "#FF4D6D", command: "#FFB86B", ask: "#8EA8FF"),
        UserTheme(name: "Lavender", accent: "#C7A6FF", command: "#FF9ECF", ask: "#8FD3FF"),
    ]

    /// Decodes a shared theme file, accepting only valid colours.
    static func decode(_ data: Data) -> UserTheme? {
        guard var t = try? JSONDecoder().decode(UserTheme.self, from: data),
              [t.accent, t.command, t.ask].allSatisfy({ Color.parseHex($0) != nil }) else { return nil }
        t.id = UUID()
        t.name = String(t.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if t.name.isEmpty { t.name = "Imported theme" }
        return t
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "Match the Mac" : rawValue.capitalized }

    @MainActor func apply() {
        switch self {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    static func parseHex(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    init(hex: String) {
        let (r, g, b) = Color.parseHex(hex) ?? (0.21, 0.84, 0.65)
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func v(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v(c.redComponent), v(c.greenComponent), v(c.blueComponent))
    }
}

// MARK: - Settings tab

struct AppearanceTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var preview = PreviewModels()
    @State private var message: String?

    var body: some View {
        Form {
            Section("Preview") {
                HStack(spacing: 14) {
                    ForEach(Array(preview.models.enumerated()), id: \.offset) { i, m in
                        VStack(spacing: 6) {
                            PillView(model: m).frame(width: 190, height: 110).allowsHitTesting(false)
                            Text(["Dictation", "Command", "Ask"][i]).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.22), Color(red: 0.22, green: 0.18, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }

            Section("Freshflo windows") {
                Picker("Appearance", selection: $settings.appAppearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Dictation indicator") {
                Picker("Style", selection: $settings.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Theme") {
                    HStack(spacing: 10) {
                        ForEach(IndicatorTheme.allCases) { theme in
                            Button { settings.indicatorTheme = theme } label: {
                                VStack(spacing: 4) {
                                    Circle().fill(IndicatorAccent.color(mode: .dictation, theme: theme, error: false))
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(Color.primary.opacity(settings.indicatorTheme == theme ? 0.9 : 0.12), lineWidth: settings.indicatorTheme == theme ? 2.5 : 1))
                                    Text(theme.label).font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(theme.label)
                        }
                    }
                }
                Slider(value: $settings.indicatorScale, in: 0.8...1.4, step: 0.05) {
                    Text("Size")
                } minimumValueLabel: { Image(systemName: "textformat.size.smaller") } maximumValueLabel: { Image(systemName: "textformat.size.larger") }
                Picker("Show it", selection: $settings.indicatorPosition) {
                    ForEach(IndicatorPosition.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Live captions while you speak", isOn: $settings.showCaptions)
                Picker("Sounds", selection: $settings.soundTheme) {
                    ForEach(SoundTheme.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Make your own theme") {
                TextField("Name", text: $settings.customTheme.name)
                ColorPicker("Dictation colour", selection: binding(\.accent), supportsOpacity: false)
                ColorPicker("Command mode colour", selection: binding(\.command), supportsOpacity: false)
                ColorPicker("Ask mode colour", selection: binding(\.ask), supportsOpacity: false)
                LabeledContent("Start from") {
                    HStack(spacing: 8) {
                        ForEach(UserTheme.presets) { p in
                            Button { use(p, keepName: false) } label: { swatch(p) }.buttonStyle(.plain).help(p.name)
                        }
                    }
                }
                HStack {
                    Button("Save theme") { save() }
                    Button("Import…") { importTheme() }
                    Button("Export…") { export(settings.customTheme) }
                    Spacer()
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }

            if !settings.savedThemes.isEmpty {
                Section("Your themes") {
                    ForEach(settings.savedThemes) { t in
                        HStack {
                            swatch(t)
                            Text(t.name)
                            Spacer()
                            Button("Use") { use(t, keepName: true) }
                            Button("Export…") { export(t) }
                            Button(role: .destructive) { settings.savedThemes.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(settings.objectWillChange) { DispatchQueue.main.async { preview.sync() } }
        .onAppear { preview.sync() }
    }

    private func binding(_ key: WritableKeyPath<UserTheme, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings.customTheme[keyPath: key]) },
                set: { settings.customTheme[keyPath: key] = $0.hexString; settings.indicatorTheme = .custom })
    }

    private func swatch(_ t: UserTheme) -> some View {
        HStack(spacing: -6) {
            ForEach([t.accent, t.command, t.ask], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 16, height: 16).overlay(Circle().stroke(.background, lineWidth: 1.5)) }
        }
    }

    private func use(_ t: UserTheme, keepName: Bool) {
        var c = t
        c.id = settings.customTheme.id
        if !keepName { c.name = settings.customTheme.name }
        settings.customTheme = c
        settings.indicatorTheme = .custom
    }

    private func save() {
        var t = settings.customTheme
        if let i = settings.savedThemes.firstIndex(where: { $0.name == t.name }) {
            t.id = settings.savedThemes[i].id
            settings.savedThemes[i] = t
            message = "Updated “\(t.name)”"
        } else {
            t.id = UUID()
            settings.savedThemes.append(t)
            message = "Saved “\(t.name)”"
        }
    }

    private func export(_ t: UserTheme) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.name).freshflotheme"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(t).write(to: url); message = "Exported" } catch { message = "Couldn't export" }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "freshflotheme") ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 10_000, let t = UserTheme.decode(data) else {
            message = "That isn't a Freshflo theme"; return
        }
        settings.savedThemes.append(t)
        use(t, keepName: true)
        message = "Imported “\(t.name)”"
    }
}

/// Three frozen indicators (dictation, command, ask) that follow your settings live.
@MainActor final class PreviewModels: ObservableObject {
    let models: [PillModel] = ([.dictation, .command, .ask] as [DictationMode]).map { mode in
        let m = PillModel()
        m.mode = mode
        m.phase = .recording
        m.startedAt = Date().addingTimeInterval(-12)
        m.meter.freeze(level: 0.6, bands: SIMD3(0.7, 0.55, 0.4))
        return m
    }

    func sync() {
        let s = AppSettings.shared
        for m in models {
            m.style = s.indicatorStyle
            m.theme = s.indicatorTheme
            m.scale = s.indicatorScale * 0.8
            m.objectWillChange.send()
        }
    }
}
