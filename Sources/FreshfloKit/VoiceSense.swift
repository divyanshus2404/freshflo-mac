import AVFoundation
import Foundation
import SoundAnalysis

/// Tells a human voice apart from everything else a mic hears (keyboard clicks, fans, music, a TV, silence).
///
/// Two listeners, like a person in the room:
/// - Fast, per 32 ms: is there enough sound above the room's noise, and is it *pitched* the way a voice is
///   (a repeating vocal-fold pattern at 70–400 Hz)? Clicks and hiss aren't; vowels are.
/// - Careful, per second: Apple's on-device sound classifier, which knows speech, whispering and conversation from
///   music, singing, typing and hundreds of other sounds.
enum VoiceSense {
    static let rate = 16_000
    static let frame = 512                 // 32 ms at 16 kHz
    private static let minLag = 40         // 400 Hz
    private static let maxLag = 228        // 70 Hz

    // MARK: Per-frame features

    struct Frame {
        var energy: Float          // RMS
        var periodicity: Float     // 0…1: how strongly the frame repeats at a voice pitch
    }

    /// Normalised autocorrelation peak over voice pitch lags.
    static func analyze(_ x: ArraySlice<Float>) -> Frame {
        let n = x.count
        let base = x.startIndex
        var e: Float = 0
        for v in x { e += v * v }
        let rms = sqrt(e / Float(max(1, n)))
        guard n >= maxLag * 2, rms > 0.0008 else { return Frame(energy: rms, periodicity: 0) }
        var best: Float = 0
        var lag = minLag
        while lag <= maxLag {
            var num: Float = 0, a: Float = 0, b: Float = 0
            let m = n - lag
            for i in 0..<m {
                let p = x[base + i], q = x[base + i + lag]
                num += p * q; a += p * p; b += q * q
            }
            let r = num / max(sqrt(a * b), 1e-9)
            if r > best { best = r }
            lag += lag < 100 ? 1 : 2   // finer where pitch periods are short
        }
        return Frame(energy: rms, periodicity: max(0, best))
    }

    /// A frame sounds like someone talking: clearly above the room's noise, and pitched like a voice.
    static func isVoice(_ f: Frame, noiseFloor: Float) -> Bool {
        let loudEnough = f.energy > max(0.0035, noiseFloor * 2.2)
        return loudEnough && f.periodicity > 0.5
    }

    /// A frame is active sound (voice, a whisper, or noise) rather than room tone.
    static func isActive(_ f: Frame, noiseFloor: Float) -> Bool {
        f.energy > max(0.0025, noiseFloor * 3)
    }

    // MARK: Live tracking (while recording)

    /// Follows the room's noise level and the speaker as audio arrives. Not thread-safe: feed from one queue.
    struct Tracker {
        private(set) var noiseFloor: Float = 0
        private(set) var voicedSeconds: Double = 0
        private(set) var elapsed: Double = 0
        /// Seconds since the last voiced frame (∞ before any voice).
        private(set) var sinceVoice: Double = .infinity
        /// The latest frame's voice-likeness, 0…1 (for the indicator).
        private(set) var voiceLevel: Float = 0
        private var pending: [Float] = []
        private var started = false

        mutating func feed(_ samples: [Float]) {
            pending += samples
            while pending.count >= VoiceSense.frame {
                let f = VoiceSense.analyze(pending[0..<VoiceSense.frame])
                pending.removeFirst(VoiceSense.frame)
                step(f)
            }
        }

        private mutating func step(_ f: Frame) {
            let dt = Double(VoiceSense.frame) / Double(VoiceSense.rate)
            elapsed += dt
            if !started { noiseFloor = f.energy; started = true }
            // The floor drops instantly to quieter frames and creeps up slowly, so speech never becomes "the room".
            noiseFloor = f.energy < noiseFloor ? f.energy : noiseFloor + (f.energy - noiseFloor) * 0.005
            if VoiceSense.isVoice(f, noiseFloor: noiseFloor) {
                voicedSeconds += dt
                sinceVoice = 0
                voiceLevel = min(1, voiceLevel * 0.4 + 0.6 * f.periodicity)
            } else {
                sinceVoice += dt
                voiceLevel *= 0.82
            }
        }
    }

    // MARK: Whole recordings

    struct Summary {
        var voicedSeconds: Double        // pitched, voice-like time
        var speechConfidence: Double     // classifier's best speech/whisper score (0…1), −1 if unavailable
        var musicConfidence: Double      // classifier's best music/singing score
        var hasHumanSpeech: Bool
    }

    static func summarize(_ s: [Float], classify: Bool = true) -> Summary {
        var t = Tracker()
        t.feed(s)
        let (speech, music) = classify ? classifier(s) : (-1, 0)
        return Summary(voicedSeconds: t.voicedSeconds, speechConfidence: speech, musicConfidence: music,
                       hasHumanSpeech: decide(voiced: t.voicedSeconds, speech: speech, music: music))
    }

    /// Is someone actually talking? Either cue can say yes (whispers have no pitch; mumbles fool the classifier),
    /// but pitched sound that the classifier is sure is music, with no speech at all, is not a person talking.
    static func decide(voiced: Double, speech: Double, music: Double) -> Bool {
        if speech >= 0.5 { return true }
        if speech < 0 { return voiced >= 0.25 }                       // classifier unavailable: pitch alone
        if music >= 0.6 && speech < 0.15 { return false }             // a song or a TV jingle
        return voiced >= 0.35 || speech >= 0.3
    }

    /// Shortens long gaps inside a recording (a pause to think, typing, a cough) to a natural half second,
    /// so the speech engine doesn't drift or invent words in silence. Speech itself is never cut.
    static func tightenPauses(_ s: [Float], longerThan: Double = 1.2, keep: Double = 0.5) -> [Float] {
        let n = s.count / frame
        guard n > 4 else { return s }
        var frames = [Frame](); frames.reserveCapacity(n)
        for i in 0..<n { frames.append(analyze(s[(i * frame)..<((i + 1) * frame)])) }
        let floor = frames.map(\.energy).sorted()[n / 10]
        let active = frames.map { isActive($0, noiseFloor: floor) || isVoice($0, noiseFloor: floor) }
        let maxGap = Int(longerThan * Double(rate) / Double(frame)), keepFrames = Int(keep * Double(rate) / Double(frame))
        var out: [Float] = []; out.reserveCapacity(s.count)
        var i = 0
        while i < n {
            if active[i] { out += s[(i * frame)..<((i + 1) * frame)]; i += 1; continue }
            var j = i
            while j < n, !active[j] { j += 1 }
            let gap = j - i
            let take = gap > maxGap ? keepFrames : gap
            // Keep the start and end of the pause so words aren't clipped at either side.
            let head = take / 2, tail = take - head
            out += s[(i * frame)..<((i + head) * frame)]
            out += s[((j - tail) * frame)..<(j * frame)]
            i = j
        }
        out += s[(n * frame)...]
        return out
    }

    // MARK: Apple's sound classifier

    private static let speechLabels = ["speech", "whispering", "conversation", "narration_monologue", "shout", "yell",
                                       "child_speech_kid_speaking", "male_speech_man_speaking", "female_speech_woman_speaking"]
    private static let musicLabels = ["music", "singing", "musical_instrument", "choir"]

    private final class Observer: NSObject, SNResultsObserving {
        var speech: Double = 0, music: Double = 0
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            for l in VoiceSense.speechLabels { if let c = r.classification(forIdentifier: l) { speech = max(speech, c.confidence) } }
            for l in VoiceSense.musicLabels { if let c = r.classification(forIdentifier: l) { music = max(music, c.confidence) } }
        }
    }

    /// Best speech and music confidence over the recording; (−1, 0) when the classifier isn't available.
    static func classifier(_ s: [Float]) -> (Double, Double) {
        guard s.count >= rate / 2,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return (-1, 0) }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = Observer()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return (-1, 0) }
        let chunk = 8192
        var pos = 0
        while pos < s.count {
            let n = min(chunk, s.count - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            s.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress! + pos, count: n) }
            analyzer.analyze(buf, atAudioFramePosition: AVAudioFramePosition(pos))
            pos += n
        }
        analyzer.completeAnalysis()
        return (observer.speech, observer.music)
    }

    // MARK: Natural endings (hands-free)

    /// Words that mean "I'm not done": a person would wait for the rest of the sentence.
    private static let continuations: Set<String> = [
        "and", "but", "so", "or", "because", "cause", "um", "uh", "erm", "like", "the", "a", "an", "to", "of", "with",
        "for", "that", "which", "if", "when", "then", "also", "my", "your", "our", "is", "are", "was", "i", "we", "you",
        "aur", "toh", "ki", "ke", "ka", "matlab", "lekin",
    ]

    /// How long a pause ends a hands-free dictation, given what was said last. A trailing "and…" or a comma earns
    /// more time to think; a finished sentence less.
    static func endPause(after text: String, base: Double) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return base }
        if t.hasSuffix(",") || t.hasSuffix("…") || t.hasSuffix("-") { return base * 1.8 }
        let last = t.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        if continuations.contains(last) { return base * 1.8 }
        if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { return base * 0.85 }
        return base
    }
}
