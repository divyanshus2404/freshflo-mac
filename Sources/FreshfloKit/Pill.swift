import AppKit
import SwiftUI

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case halo, minimal

    var id: String { rawValue }
    var label: String { self == .halo ? "Glass (default)" : "Minimal (compact bar)" }
}

enum IndicatorTheme: String, CaseIterable, Identifiable {
    case fresh, aurora, sunset, mono, matrix

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum IndicatorPosition: String, CaseIterable, Identifiable {
    case caret, bottom

    var id: String { rawValue }
    var label: String { self == .caret ? "At the text cursor" : "Bottom of the screen" }
}

// MARK: - Audio meter

/// Audio values for the animation. Deliberately *not* @Published: audio arrives ~23×/s in steps, and publishing it
/// re-rendered the whole indicator in jerks. Views read it every display frame and ease toward the latest target,
/// so motion is smooth at 60 fps regardless of how chunky the audio callbacks are.
final class AudioMeter {
    private(set) var level: Float = 0
    private(set) var bands = SIMD3<Float>(repeating: 0)
    private var targetLevel: Float = 0
    private var targetBands = SIMD3<Float>(repeating: 0)
    private var lastTick: Date?

    func setTarget(level: Float) { targetLevel = level }
    func setTarget(bands: SIMD3<Float>) { targetBands = bands }

    /// Frame-rate-independent easing: fast attack, gentler release. Safe to call from several views per frame.
    func tick(_ now: Date) {
        let dt = Float(min(0.1, max(0, now.timeIntervalSince(lastTick ?? now))))
        lastTick = now
        guard dt > 0 else { return }
        func ease(_ current: Float, _ target: Float) -> Float {
            let rate: Float = target > current ? 22 : 7
            return current + (target - current) * (1 - exp(-rate * dt))
        }
        level = ease(level, targetLevel)
        bands = SIMD3(ease(bands[0], targetBands[0]), ease(bands[1], targetBands[1]), ease(bands[2], targetBands[2]))
    }

    func reset() {
        level = 0; bands = .zero; targetLevel = 0; targetBands = .zero; lastTick = nil
    }

    /// For still previews: jump straight to the given values.
    func freeze(level: Float, bands: SIMD3<Float>) {
        self.level = level; self.bands = bands; targetLevel = level; targetBands = bands
    }
}

final class PillModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case processing(String)
        case done(String)
        case message(String, isError: Bool)
    }

    @Published var phase: Phase = .hidden
    @Published var locked = false
    @Published var mode: DictationMode = .dictation
    @Published var startedAt = Date()
    @Published var style: IndicatorStyle = .halo
    @Published var theme: IndicatorTheme = .fresh
    /// Pinned next to the caret: grow to the right only, so the orb never moves.
    @Published var anchoredLeading = false
    /// Gentle nudge when we've heard almost nothing for a while.
    @Published var hint: String?
    /// Words heard so far (live preview).
    @Published var liveText = "" {
        didSet {
            // Only *new* words animate in; the recognizer revising earlier words must not flicker.
            let count = liveText.split(separator: " ").count
            if count > liveWordCount { newWordID += 1 }
            liveWordCount = count
        }
    }
    @Published private(set) var newWordID = 0
    private var liveWordCount = 0

    let meter = AudioMeter()
    private var quietSince: Date?

    func push(_ value: Float) {
        meter.setTarget(level: value)
        guard phase == .recording else { return }
        let now = Date()
        if value < 0.12, liveText.isEmpty {
            quietSince = quietSince ?? now
            if hint == nil, now.timeIntervalSince(quietSince!) > 2.5, now.timeIntervalSince(startedAt) > 2.5 {
                hint = "Too quiet? Speak up or check your mic"
            }
        } else {
            quietSince = nil
            if hint != nil { hint = nil }
        }
    }

    func pushBands(_ value: SIMD3<Float>) {
        meter.setTarget(bands: value)
    }

    func resetForRecording() {
        meter.reset()
        hint = nil
        quietSince = nil
        liveWordCount = 0
        liveText = ""
    }
}

// MARK: - Accent

/// One restrained accent colour per mode/theme; everything else is white-on-glass.
enum IndicatorAccent {
    static func color(mode: DictationMode, theme: IndicatorTheme, error: Bool) -> Color {
        if error { return Color(red: 1.0, green: 0.72, blue: 0.32) }
        switch mode {
        case .command: return Color(red: 0.72, green: 0.58, blue: 1.0)
        case .ask: return Color(red: 0.42, green: 0.67, blue: 1.0)
        case .dictation:
            switch theme {
            case .fresh: return Color(red: 0.21, green: 0.84, blue: 0.65)
            case .aurora: return Color(red: 0.52, green: 0.70, blue: 1.0)
            case .sunset: return Color(red: 1.0, green: 0.58, blue: 0.45)
            case .mono: return Color(white: 0.94)
            case .matrix: return Color(red: 0.38, green: 0.95, blue: 0.58)
            }
        }
    }
}

// MARK: - Voice waveform

/// A single mirrored waveform envelope: smooth, monochrome, with the accent only at its heart.
private struct VoiceWave: View {
    let time: Double
    let level: Double
    let bands: SIMD3<Float>
    let accent: Color

    var body: some View {
        let t = time
        Canvas { ctx, size in
            let w = Double(size.width), mid = Double(size.height) / 2
            let energy = 0.06 + 0.94 * level
            // Brighter consonants make the texture finer; bass makes it broader.
            let fine = 0.09 + Double(bands[2]) * 0.05
            let broad = 0.028 + Double(bands[0]) * 0.012
            var top: [CGPoint] = []
            for x in stride(from: 0.0, through: w, by: 2) {
                let p = x / w
                let taper = pow(sin(p * .pi), 1.6)
                let texture = 0.55 + 0.45 * sin(x * fine + t * 5.2) * sin(x * broad - t * 2.3)
                let h = max(0.6, mid * energy * taper * texture)
                top.append(CGPoint(x: x, y: mid - h))
            }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: mid))
            for pt in top { path.addLine(to: pt) }
            for pt in top.reversed() { path.addLine(to: CGPoint(x: pt.x, y: 2 * mid - pt.y)) }
            path.closeSubpath()
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.18), location: 0),
                    .init(color: accent.opacity(0.95), location: 0.35),
                    .init(color: .white.opacity(0.95), location: 0.5),
                    .init(color: accent.opacity(0.95), location: 0.65),
                    .init(color: .white.opacity(0.18), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            ctx.fill(path, with: shading)
        }
    }
}

// MARK: - Glass indicator

/// The default indicator: a small dark-glass capsule with a hairline edge light, a breathing dot and one waveform.
private struct HaloView: View {
    @ObservedObject var model: PillModel
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Fixed centre width so the capsule never resizes as words arrive.
    static let centerWidth: CGFloat = 230
    static let height: CGFloat = 38

    private var isError: Bool {
        if case .message(_, true) = model.phase { return true }
        return false
    }
    private var isProcessing: Bool {
        if case .processing = model.phase { return true }
        return false
    }
    private var animating: Bool { model.phase == .recording || isProcessing }
    private var accent: Color { IndicatorAccent.color(mode: model.mode, theme: model.theme, error: isError) }
    private static var fps: Double { ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60 }

    private func clock<V: View>(fps: Double? = nil, @ViewBuilder _ draw: @escaping (Double) -> V) -> some View {
        TimelineView(.animation(minimumInterval: 1 / min(fps ?? Self.fps, Self.fps), paused: !animating)) { ctx in
            let _ = model.phase == .recording ? model.meter.tick(ctx.date) : ()
            draw(reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate)
        }
    }

    var body: some View {
        if model.phase != .hidden {
            HStack(spacing: 10) {
                leading
                center
                trailing
            }
            .padding(.leading, 13)
            .padding(.trailing, 15)
            .frame(height: Self.height)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.62))
                    .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            )
            .overlay(edgeLight)
            .environment(\.colorScheme, .dark)
            .animation(.smooth(duration: 0.3), value: model.phase)
            .animation(.smooth(duration: 0.3), value: model.mode)
        }
    }

    /// A faint arc of light travelling around the edge while listening or thinking.
    @ViewBuilder private var edgeLight: some View {
        if animating {
            // Slow-moving light: 30 fps looks identical and halves its cost.
            clock(fps: 30) { t in
                let angle = (t * (isProcessing ? 140 : 70)).truncatingRemainder(dividingBy: 360)
                Capsule(style: .continuous)
                    .strokeBorder(
                        AngularGradient(stops: [
                            .init(color: accent.opacity(0), location: 0),
                            .init(color: accent.opacity(0.75), location: 0.12),
                            .init(color: accent.opacity(0), location: 0.3),
                            .init(color: accent.opacity(0), location: 1),
                        ], center: .center, angle: .degrees(angle)),
                        lineWidth: 1)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .recording:
            clock { _ in
                let l = CGFloat(model.meter.level)
                ZStack {
                    Circle().fill(accent.opacity(0.22)).frame(width: 16, height: 16).scaleEffect(0.6 + l * 0.7)
                    Circle().fill(accent).frame(width: 7, height: 7).scaleEffect(1 + l * 0.35)
                }
                .frame(width: 16, height: 16)
            }
        case .processing:
            clock { t in
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees((t * 360).truncatingRemainder(dividingBy: 360)))
                    .background(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.6).frame(width: 12, height: 12))
                    .frame(width: 16, height: 16)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16, height: 16)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .message(_, let error):
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16, height: 16)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var center: some View {
        switch model.phase {
        case .recording:
            ZStack(alignment: .trailing) {
                if !model.liveText.isEmpty {
                    LiveWords(text: model.liveText, newWordID: model.newWordID)
                        .frame(width: Self.centerWidth, height: 20, alignment: .trailing)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black, location: 0.16)],
                                             startPoint: .leading, endPoint: .trailing))
                        .transition(.opacity)
                } else if let hint = model.hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(width: Self.centerWidth, alignment: .leading)
                        .transition(.opacity)
                } else {
                    clock { t in
                        VoiceWave(time: t, level: Double(model.meter.level), bands: model.meter.bands, accent: accent)
                    }
                    .frame(width: Self.centerWidth, height: 20)
                    .transition(.opacity)
                }
            }
            .frame(width: Self.centerWidth, height: 20)
            .animation(.smooth(duration: 0.25), value: model.liveText.isEmpty)
            .animation(.smooth(duration: 0.25), value: model.hint)
        case .processing(let label):
            Text(label.replacingOccurrences(of: "…", with: ""))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize()
        case .done(let label):
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
        case .message(let text, _):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .frame(maxWidth: 380, alignment: .leading)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.phase == .recording, model.mode != .dictation || model.locked {
            HStack(spacing: 8) {
                if model.mode != .dictation {
                    Text(model.mode == .ask ? "Ask" : "Command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }
                if model.locked {
                    TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                        Text(elapsed(ctx.date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Only the newest word materializes out of a blur; earlier text stays perfectly still.
private struct LiveWords: View {
    let text: String
    let newWordID: Int

    var body: some View {
        let words = text.split(separator: " ")
        HStack(spacing: 4) {
            if words.count > 1 {
                Text(words.dropLast().joined(separator: " "))
            }
            if let last = words.last {
                Text(last)
                    .id(newWordID)
                    .transition(.modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0)))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        .fixedSize()
        .animation(.easeOut(duration: 0.22), value: newWordID)
    }
}

private struct BlurFade: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: amount * 4).opacity(1 - amount)
    }
}

// MARK: - Minimal (compact bar)

private struct MinimalPillView: View {
    @ObservedObject var model: PillModel

    private var accent: Color {
        if model.mode == .command { return Color(red: 0.62, green: 0.48, blue: 1.0) }
        if model.mode == .ask { return Color(red: 0.25, green: 0.78, blue: 0.85) }
        return model.locked ? .orange : .red
    }

    var body: some View {
        if model.phase != .hidden {
            HStack(spacing: 10) {
                switch model.phase {
                case .hidden:
                    EmptyView()
                case .recording:
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { ctx in
                        let _ = model.meter.tick(ctx.date)
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let level = CGFloat(model.meter.level)
                        HStack(spacing: 10) {
                            Circle().fill(accent).frame(width: 7, height: 7).opacity(0.6 + 0.4 * sin(t * 4))
                            HStack(alignment: .center, spacing: 2.5) {
                                ForEach(0..<16, id: \.self) { i in
                                    let wobble = 0.55 + 0.45 * sin(t * 7 + Double(i) * 0.8)
                                    Capsule()
                                        .fill(Color.white.opacity(0.92))
                                        .frame(width: 3, height: max(3, level * 22 * CGFloat(wobble)))
                                }
                            }
                            .frame(height: 24)
                        }
                    }
                    if model.mode != .dictation {
                        Text(model.mode == .ask ? "Ask" : "Command").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    }
                    if !model.liveText.isEmpty {
                        Text(model.liveText)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(width: 300, alignment: .trailing)
                    }
                case .processing(let label):
                    ProgressView().controlSize(.small)
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                case .done(let label):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                case .message(let text, let isError):
                    Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Color.yellow : Color.green)
                    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Capsule().fill(Color.black.opacity(0.86)))
            .overlay(Capsule().strokeBorder(model.mode != .dictation ? accent.opacity(0.5) : Color.white.opacity(0.14), lineWidth: 1))
            .environment(\.colorScheme, .dark)
        }
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                if model.anchoredLeading {
                    // Pinned at the caret: the orb stays put and the capsule grows to the right.
                    indicator.padding(.leading, PillController.leadingInset)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    indicator
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, PillController.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var indicator: some View {
        if model.style == .halo { HaloView(model: model) } else { MinimalPillView(model: model) }
    }
}

// MARK: - Controller

/// Floating, non-activating indicator.
final class PillController {
    static let bottomInset: CGFloat = 22
    static let leadingInset: CGFloat = 40
    private static let capsuleHeight: CGFloat = 38

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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 130),
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
        self.anchor = settings.indicatorPosition == .caret ? anchor : nil
        model.anchoredLeading = self.anchor != nil
        model.style = settings.indicatorStyle
        model.theme = settings.indicatorTheme
        model.resetForRecording()
        model.mode = mode
        model.locked = locked
        model.startedAt = Date()
        model.phase = .recording
        present()
    }

    func showProcessing(_ label: String) {
        model.phase = .processing(label)
        present()
    }

    /// Brief confirmation (ripple + check) after text lands, then dissolves.
    func success(_ label: String) {
        model.phase = .done(label)
        present()
        scheduleHide(after: 0.9)
    }

    func flash(_ message: String, seconds: Double = 2.4, isError: Bool = true) {
        model.phase = .message(message, isError: isError)
        present()
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
        guard let frame = screen?.visibleFrame else { return panel.frame.origin }
        return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 6)
    }
}

// MARK: - Preview rendering (CLI: --render-pill out.png)

enum PillPreview {
    /// Renders every indicator state onto a desktop-like backdrop so the design can be reviewed without dictating.
    @MainActor
    static func render(to url: URL) {
        func model(_ phase: PillModel.Phase, mode: DictationMode = .dictation, live: String = "", locked: Bool = false, level: Float = 0.6,
                   theme: IndicatorTheme = .fresh, bands: SIMD3<Float> = SIMD3(0.6, 0.5, 0.4), hint: String? = nil) -> PillModel {
            let m = PillModel()
            m.theme = theme
            m.phase = phase
            m.mode = mode
            m.liveText = live
            m.locked = locked
            m.hint = hint
            m.startedAt = Date().addingTimeInterval(-74)
            m.meter.freeze(level: level, bands: bands)
            return m
        }
        let states: [(String, PillModel)] = [
            ("Dictating", model(.recording)),
            ("Bass-heavy voice", model(.recording, bands: SIMD3(0.95, 0.4, 0.1))),
            ("Hands-free + too quiet", model(.recording, locked: true, level: 0.05, bands: .zero, hint: "Too quiet? Speak up or check your mic")),
            ("Live words", model(.recording, live: "so I was thinking we could meet on Wednesday and can you send the deck")),
            ("Theme: Sunset", model(.recording, theme: .sunset)),
            ("Command", model(.recording, mode: .command, level: 0.4)),
            ("Ask", model(.recording, mode: .ask, level: 0.5)),
            ("Processing", model(.processing("Polishing…"))),
            ("Done", model(.done("24 words"))),
            ("Error", model(.message("Network is offline — audio saved, retry from the menu", isError: true))),
        ]
        let view = VStack(alignment: .center, spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    Text(item.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    HaloView(model: item.1)
                }
            }
        }
        .padding(40)
        .frame(width: 760)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.22), Color(red: 0.22, green: 0.18, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
