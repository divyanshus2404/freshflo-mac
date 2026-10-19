import AppKit
import SwiftUI

// MARK: - Dot wave

/// The Glass indicator's voice: a row of dots that rise into bars as you speak, breathe gently in silence,
/// and turn into a travelling shimmer while Freshflo polishes. Same width in every state, so nothing jumps.
struct DotWave: View {
    enum Mode { case listening, thinking }
    let mode: Mode
    let time: Double
    let level: Double
    let bands: SIMD3<Float>
    let accent: Color
    var fluid = false

    static let count = 15
    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 3
    static var width: CGFloat { CGFloat(count) * barWidth + CGFloat(count - 1) * gap }

    var body: some View {
        Canvas { ctx, size in
            let n = Self.count, mid = size.height / 2, maxH = size.height
            for i in 0..<n {
                let x = CGFloat(i) * (Self.barWidth + Self.gap)
                let center = 1 - abs(Double(i) - Double(n - 1) / 2) / (Double(n - 1) / 2)   // 1 in the middle, 0 at the ends
                var h: Double
                var alpha: Double
                switch mode {
                case .listening:
                    // Low notes move the middle, high notes the edges; every bar has its own gentle rhythm.
                    let band = Double(i < n / 3 ? bands[2] : i < 2 * n / 3 ? bands[0] : bands[1])
                    // A voice-shaped envelope (tallest in the middle) with a slow, smooth shimmer on top.
                    let envelope = 0.25 + 0.75 * pow(center, 1.2)
                    let motion = 0.72 + 0.28 * sin(time * 4.2 + Double(i) * 0.9) * cos(time * 1.7 - Double(i) * 0.5)
                    let voice = level * envelope * (0.8 + 0.2 * band) * motion
                    let breathe = 0.13 + 0.08 * (0.5 + 0.5 * sin(time * 2.2 - Double(i) * 0.45))   // calm "I'm listening" ripple
                    h = max(breathe, min(1, voice * 1.9))
                    alpha = 0.55 + 0.45 * min(1, h * 1.5)
                case .thinking:
                    // A soft light that travels left to right across resting dots.
                    let pos = (time * 0.9).truncatingRemainder(dividingBy: 1.4) - 0.2
                    let d = abs(Double(i) / Double(n - 1) - pos)
                    let glow = max(0, 1 - d * 5)
                    h = 0.18 + 0.22 * glow
                    alpha = 0.3 + 0.7 * glow
                }
                let barH = max(Self.barWidth, CGFloat(h) * maxH)
                let rect = CGRect(x: x, y: mid - barH / 2, width: Self.barWidth, height: barH)
                // White at the edges, the accent colour toward the middle.
                // Fluid: a gradient flowing across every dot instead.
                let color = fluid ? IndicatorAccent.fluid(time * IndicatorAccent.fluidSpeed + Double(i) / Double(n) * 0.45)
                                  : center > 0.7 ? accent : Color.white
                ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(color.opacity(alpha)))
            }
        }
        .frame(width: Self.width)
    }
}

/// A checkmark that draws itself.
struct DrawnCheck: View {
    let color: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 1.5, y: 6.5))
            p.addLine(to: CGPoint(x: 4.8, y: 9.6))
            p.addLine(to: CGPoint(x: 10.5, y: 2.5))
        }
        .trim(from: 0, to: progress)
        .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        .frame(width: 12, height: 12)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { progress = 1 } }
    }
}

// MARK: - Glass indicator

/// The default indicator: a small dark-glass capsule holding nothing but a dot wave of your voice.
/// Polishing turns the same dots into a shimmer; done draws a check. Minimal, and the same size throughout.
struct HaloView: View {
    @ObservedObject var model: PillModel
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static let height: CGFloat = 30

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
            HStack(spacing: 9) {
                content
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .background(glass)
            .background(voiceGlow)
            .environment(\.colorScheme, .dark)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
            .animation(.smooth(duration: 0.3), value: model.mode)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// Dark glass with a fine light edge: brighter on top, fading at the bottom, like light catching a lens.
    private var glass: some View {
        Capsule(style: .continuous)
            .fill(Color.black.opacity(0.76))
            .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    /// A faint pool of accent light under the capsule that grows with your voice.
    @ViewBuilder private var voiceGlow: some View {
        if model.phase == .recording {
            clock(fps: 30) { _ in
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.1 + 0.35 * Double(model.meter.level)))
                    .blur(radius: 12)
                    .scaleEffect(x: 0.9, y: 0.7)
                    .offset(y: 6)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            if let hint = model.hint {
                Image(systemName: "mic.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1).fixedSize()
            } else {
                clock { t in
                    DotWave(mode: .listening, time: t, level: Double(model.meter.level), bands: model.meter.bands, accent: accent, fluid: model.theme == .fluid && model.mode == .dictation && !isError)
                }
                .frame(height: 16)
            }
            trailing
        case .processing(let label):
            clock { t in
                DotWave(mode: .thinking, time: t, level: 0, bands: .zero, accent: accent, fluid: model.theme == .fluid && model.mode == .dictation)
            }
            .frame(height: 16)
            // Transcribing and polishing need no words; anything slower says what's happening.
            if !["Transcribing…", "Polishing…"].contains(label) {
                Text(label.replacingOccurrences(of: "…", with: "")).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).fixedSize()
            }
        case .done(let label):
            DrawnCheck(color: accent)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.78)).fixedSize()
        case .message(let text, let error):
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.mode != .dictation || model.locked {
            HStack(spacing: 7) {
                if model.mode != .dictation {
                    Text(model.mode == .ask ? "Ask" : "Command")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accent)
                }
                if model.locked {
                    TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                        Text(elapsed(ctx.date))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
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

// MARK: - Live captions

/// What you're saying (fillers and self-corrections shown struck through, the way Freshflo will drop them)
/// and what it detects: a list or sentences, a question, a correction. After a dictation it shows what was typed.
struct CaptionsCard: View {
    @ObservedObject var model: PillModel
    let accent: Color
    static let width: CGFloat = 460

    private var phaseKey: Int {
        switch model.phase {
        case .recording: return 1
        case .processing: return 2
        case .done: return 3
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                header
                Spacer(minLength: 10)
                chips
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.74))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        )
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.25), value: model.insight)
        .animation(.smooth(duration: 0.25), value: phaseKey)
    }

    @ViewBuilder private var header: some View {
        let label: String = {
            switch model.phase {
            case .done: return model.appLabel.isEmpty ? "Typed" : "Typed into \(model.appLabel.components(separatedBy: " · ").first ?? "")"
            case .processing: return "Polishing"
            default: return model.appLabel.isEmpty ? "Listening" : model.appLabel
            }
        }()
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }

    @ViewBuilder private var chips: some View {
        let insight = model.finalText.map(CaptionInsight.of) ?? model.insight
        HStack(spacing: 5) {
            if model.finalText == nil {
                if insight.fillers > 0 { chip(insight.fillers == 1 ? "1 filler" : "\(insight.fillers) fillers", strong: false) }
                if insight.correction { chip("Correction", strong: false) }
                if let language = insight.language { chip(language, strong: false) }
            }
            if !insight.structure.isEmpty { chip(insight.structure, strong: insight.isList) }
        }
    }

    private func chip(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(strong ? accent : .white.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(strong ? accent.opacity(0.16) : Color.white.opacity(0.08)))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder private var content: some View {
        if let final = model.finalText {
            Text(final)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(7)
                .transition(.opacity)
        } else if !model.captionsAvailable {
            Text("Captions need Apple's on-device speech for your language. Turn on Speech Recognition, or download the speech model, in Settings → General.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
        } else if model.liveText.isEmpty {
            Text(model.phase == .recording ? "Start talking…" : "")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            CaptionText(text: model.liveText)
                .opacity(model.phase == .recording ? 1 : 0.55)
        }
    }
}

/// The words heard so far: the last few lines, with fillers and self-corrections struck through.
struct CaptionText: View {
    let text: String
    private static let maxWords = 48

    var body: some View {
        var words = text.split(separator: " ").map(String.init)
        let trimmed = words.count > Self.maxWords
        if trimmed { words = Array(words.suffix(Self.maxWords)) }
        let marked = Self.marks(words)
        var line = Text(trimmed ? "… " : "")
        for (i, word) in words.enumerated() {
            let piece = Text(word)
            line = line + (marked[i] ? piece.foregroundColor(.white.opacity(0.32)).strikethrough(true, color: .white.opacity(0.32)) : piece.foregroundColor(.white.opacity(0.94)))
            if i < words.count - 1 { line = line + Text(" ") }
        }
        return line
            .font(.system(size: 14.5))
            .lineLimit(3)
            .truncationMode(.head)
    }

    /// Fillers ("um", "uh") and the words a self-correction replaces ("Tuesday no wait" in "Tuesday no wait Wednesday").
    static func marks(_ words: [String]) -> [Bool] {
        let keys = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var marked = keys.map { CaptionInsight.fillerWords.contains($0) }
        for i in keys.indices where i + 1 < keys.count {
            let pair = keys[i] + " " + keys[i + 1]
            guard CaptionInsight.correctionPhrases.contains(pair) else { continue }
            marked[i] = true
            marked[i + 1] = true
            // The word just before "no wait" is the one being replaced.
            if i > 0 { marked[i - 1] = true }
        }
        return marked
    }
}

// MARK: - Minimal (compact bar)

struct MinimalPillView: View {
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

// MARK: - Expressive styles (Orb, Island, Equalizer, Glow line)

/// The recording look differs per style; thinking, done and messages reuse the Glass capsule so they read the same everywhere.
struct ExpressiveIndicator: View {
    @ObservedObject var model: PillModel
    let style: IndicatorStyle
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var accent: Color { IndicatorAccent.color(mode: model.mode, theme: model.theme, error: false) }

    var body: some View {
        if model.phase == .recording {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { ctx in
                let _ = model.meter.tick(ctx.date)
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                let level = Double(model.meter.level)
                switch style {
                case .orb: orb(t, level)
                case .island: island(t, level)
                case .bars: bars(t, level)
                default: line(t, level)
                }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            HaloView(model: model)
        }
    }

    // Orb: a single living sphere that breathes with your voice. No text, no chrome.
    private func orb(_ t: Double, _ level: Double) -> some View {
        let size: CGFloat = 38
        return ZStack {
            Circle().fill(accent.opacity(0.18)).frame(width: size * 1.7, height: size * 1.7).scaleEffect(0.75 + level * 0.45).blur(radius: 8)
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.95), accent, accent.opacity(0.75)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.7))
                .overlay(
                    Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.35), .clear, accent.opacity(0.5), .clear], center: .center, angle: .degrees(t * 90)))
                        .blendMode(.plusLighter)
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.6))
                .frame(width: size, height: size)
                .scaleEffect(1 + level * 0.28 + 0.02 * sin(t * 2.4))
                .shadow(color: accent.opacity(0.55), radius: 10 + level * 10)
            if model.locked {
                Text(elapsed).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.55))).offset(y: size * 0.9)
            }
        }
        .frame(width: size * 1.9, height: size * 1.9)
    }

    // Island: a black pill that hangs from the top of the screen, like the iPhone's Dynamic Island.
    private func island(_ t: Double, _ level: Double) -> some View {
        HStack(spacing: 10) {
            Circle().fill(accent).frame(width: 7, height: 7).shadow(color: accent, radius: 4).opacity(0.65 + 0.35 * sin(t * 4))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<18, id: \.self) { i in
                    let shape = sin(Double(i + 1) / 19 * .pi)
                    let wobble = 0.35 + 0.65 * abs(sin(t * 6.3 + Double(i) * 0.9) * cos(t * 2.1 + Double(i) * 0.4))
                    Capsule().fill(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                        .frame(width: 2.5, height: max(2.5, 18 * shape * (0.15 + level * 0.85) * wobble))
                }
            }
            .frame(height: 20)
            if model.locked {
                Text(elapsed).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Capsule(style: .continuous).fill(Color.black))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    // Equalizer: chunky rounded bars that bounce with bass, mids and highs.
    private func bars(_ t: Double, _ level: Double) -> some View {
        let bands = model.meter.bands
        return HStack(alignment: .center, spacing: 4) {
            ForEach(0..<9, id: \.self) { i in
                let band = Double(i < 3 ? bands[0] : i < 6 ? bands[1] : bands[2])
                let center = 1 - abs(Double(i) - 4) / 5
                let wobble = 0.55 + 0.45 * sin(t * 8 + Double(i) * 1.3)
                let h = max(5, 24 * (0.15 + (level * 0.6 + band * 0.4) * center * wobble))
                Capsule().fill(i == 4 ? accent : .white.opacity(0.92)).frame(width: 4.5, height: h)
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            Capsule(style: .continuous).fill(Color.black.opacity(0.78))
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    // Glow line: just your voice as a line of light floating over whatever you're doing. No background at all.
    private func line(_ t: Double, _ level: Double) -> some View {
        Canvas { ctx, size in
            let w = Double(size.width), mid = Double(size.height) / 2
            var path = Path()
            for x in stride(from: 0.0, through: w, by: 2) {
                let p = x / w
                let taper = pow(sin(p * .pi), 1.4)
                let y = mid + sin(x * 0.075 + t * 7) * sin(x * 0.021 - t * 2.6) * mid * 0.9 * taper * (0.08 + level * 0.92)
                x == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [accent.opacity(0), accent, .white, accent, accent.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0))
            var glow = ctx
            glow.addFilter(.blur(radius: 5))
            glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .frame(width: 200, height: 40)
        .shadow(color: .black.opacity(0.25), radius: 6)
    }

    private var elapsed: String {
        let s = max(0, Int(Date().timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            if !model.style.atTop { Spacer(minLength: 0) }
            HStack {
                if model.anchoredLeading {
                    // Pinned at the caret: the orb stays put and the capsule grows to the right.
                    indicator.scaleEffect(model.scale, anchor: .bottomLeading).padding(.leading, PillController.leadingInset)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    indicator.scaleEffect(model.scale, anchor: model.style.atTop ? .top : .bottom)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, model.style.atTop ? 0 : PillController.bottomInset)
        .padding(.top, model.style.atTop ? model.topInset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.style.atTop ? .top : .bottom)
    }

    @ViewBuilder private var indicator: some View {
        VStack(spacing: 10) {
            if showCaptions, !model.style.atTop {
                CaptionsCard(model: model, accent: IndicatorAccent.color(mode: model.mode, theme: model.theme, error: false))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            switch model.style {
            case .halo: HaloView(model: model)
            case .minimal: MinimalPillView(model: model)
            default: ExpressiveIndicator(model: model, style: model.style)
            }
            // The island hangs from the top, so its captions sit underneath it.
            if showCaptions, model.style.atTop {
                CaptionsCard(model: model, accent: IndicatorAccent.color(mode: model.mode, theme: model.theme, error: false))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: showCaptions)
    }

    private var showCaptions: Bool {
        guard model.captionsOn, model.mode == .dictation else { return false }
        switch model.phase {
        case .recording, .processing: return true
        case .done: return model.finalText != nil
        default: return false
        }
    }
}
