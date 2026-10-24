import AppKit
import SwiftUI

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case halo, orb, island, bars, line, minimal

    var id: String { rawValue }
    var label: String {
        switch self {
        case .halo: return "Glass"
        case .orb: return "Orb"
        case .island: return "Island (top of screen)"
        case .bars: return "Equalizer"
        case .line: return "Glow line"
        case .minimal: return "Compact bar"
        }
    }
    /// Sits at the top of the screen, under the notch, instead of at the bottom or the cursor.
    var atTop: Bool { self == .island }
}

enum IndicatorTheme: String, CaseIterable, Identifiable {
    case fluid, fresh, aurora, sunset, mono, matrix, custom

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
    /// The "Write in" chip above the bar while dictating ("→ English"); nil hides it.
    @Published var writeIn: String?
    /// Where the chip is, in the bar window's top-left coordinates, so only it takes clicks.
    var chipFrame: CGRect = .zero
    var onChipTap: (() -> Void)?
    @Published var mode: DictationMode = .dictation
    @Published var startedAt = Date()
    @Published var style: IndicatorStyle = .halo
    @Published var theme: IndicatorTheme = .fresh
    @Published var scale: Double = 1
    /// Pinned next to the caret: grow to the right only, so the orb never moves.
    @Published var anchoredLeading = false
    /// Island style: gap from the top of the panel (clears the notch / menu bar).
    @Published var topInset: CGFloat = 6
    /// Gentle nudge when we've heard almost nothing for a while.
    @Published var hint: String?
    /// Words heard so far (live preview).
    @Published var liveText = "" {
        didSet {
            // Only *new* words animate in; the recognizer revising earlier words must not flicker.
            let count = liveText.split(separator: " ").count
            if count > liveWordCount { newWordID += 1 }
            liveWordCount = count
            let next = CaptionInsight.of(liveText)
            if next != insight { insight = next }
        }
    }
    /// Live captions card above the bar.
    @Published var captionsOn = false
    /// False when this Mac can't recognise the language on-device (captions show how to fix it).
    @Published var captionsAvailable = true
    /// "Slack · Casual": where the text goes and in which style.
    @Published var appLabel = ""
    /// What was typed, shown briefly in the captions card after a dictation.
    @Published var finalText: String?
    /// What Freshflo detects in the words so far: list or sentences, a self-correction, fillers.
    @Published private(set) var insight = CaptionInsight.empty
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
        finalText = nil
    }
}

extension PillModel {
    /// Short label for the chip: where your words are going.
    static func chipLabel(_ writeIn: String) -> String {
        writeIn.isEmpty ? "As spoken" : "→ " + (writeIn.components(separatedBy: " (").first ?? writeIn)
    }
}

// MARK: - Caption insight

/// What the captions card says it detects, from the raw words heard so far.
struct CaptionInsight: Equatable {
    var structure: String
    var isList = false
    var correction = false
    var fillers = 0
    var language: String?

    static let empty = CaptionInsight(structure: "")
    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]
    static let correctionPhrases = ["no wait", "wait no", "i mean", "scratch that", "or rather", "sorry i meant", "let me rephrase", "actually no"]
    private static let questionStarters: Set<String> = ["what", "why", "how", "who", "when", "where", "which", "can", "could", "would", "should",
                                                         "is", "are", "do", "does", "did", "will", "have", "has"]

    static func of(_ text: String) -> CaptionInsight {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return .empty }
        let fillers = words.filter(fillerWords.contains).count
        let joined = " " + words.joined(separator: " ") + " "
        let correction = correctionPhrases.contains { joined.contains(" \($0) ") }
        let list = ListFormat.detect(text)
        var structure: String
        switch list.kind {
        case .numbered: structure = "Numbered list · \(list.items)"
        case .bulleted: structure = list.items == 1 ? "Bullet points" : "Bullet points · \(list.items)"
        case nil:
            let first = words.first { !fillerWords.contains($0) && $0 != "so" && $0 != "okay" }
            let sentences = text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            if text.trimmingCharacters(in: .whitespaces).hasSuffix("?") || (first.map(questionStarters.contains) ?? false) {
                structure = "Question"
            } else {
                structure = sentences > 1 ? "\(sentences) sentences" : "Sentence"
            }
        }
        var result = CaptionInsight(structure: structure, isList: list.kind != nil, correction: correction, fillers: fillers)
        // The language you're speaking (and what it'll be written in), once there's enough to tell.
        if words.count >= 4, let spoken = LanguageID.detect(text: text, whisperGuess: nil, hints: AppSettings.shared.spokenLanguages) {
            let target = AppSettings.shared.outputLanguage.components(separatedBy: " (").first ?? ""
            if !target.isEmpty, target != spoken.name { result.language = "\(spoken.name) → \(target)" }
            else if spoken.code != "en" || spoken.hinglish { result.language = spoken.name }
        }
        return result
    }
}

// MARK: - Accent

/// One restrained accent colour per mode/theme; everything else is white-on-glass.
enum IndicatorAccent {
    static func color(mode: DictationMode, theme: IndicatorTheme, error: Bool) -> Color {
        if error { return Color(red: 1.0, green: 0.72, blue: 0.32) }
        if theme == .custom {
            let t = AppSettings.shared.customTheme
            switch mode {
            case .command: return Color(hex: t.command)
            case .ask: return Color(hex: t.ask)
            case .dictation: return Color(hex: t.accent)
            }
        }
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
            case .custom: return Color(hex: AppSettings.shared.customTheme.accent)
            case .fluid: return fluid(Date().timeIntervalSinceReferenceDate * fluidSpeed)
            }
        }
    }
}

extension IndicatorAccent {
    /// Fluid: soft pastels (mint, sky, lavender, rose, peach) that melt into each other.
    static let fluidStops: [(Double, Double, Double)] = [
        (0.37, 0.90, 0.76), (0.44, 0.72, 1.0), (0.72, 0.61, 1.0), (1.0, 0.62, 0.78), (1.0, 0.77, 0.54),
    ]
    /// Cycles per second of the slow drift (one full loop every ~12 s: calm, never flashy).
    static let fluidSpeed = 0.085

    /// The colour at a point on the loop (any number; wraps around), eased so blends stay smooth.
    static func fluid(_ phase: Double) -> Color {
        let n = Double(fluidStops.count)
        var p = phase.truncatingRemainder(dividingBy: 1); if p < 0 { p += 1 }
        let x = p * n, i = Int(x) % fluidStops.count, j = (i + 1) % fluidStops.count
        let f = x - floor(x), t = f * f * (3 - 2 * f)
        let a = fluidStops[i], b = fluidStops[j]
        return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }
}
