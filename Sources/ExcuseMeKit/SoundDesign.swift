import AppKit
import AVFoundation

enum SoundTheme: String, CaseIterable, Identifiable {
    case chimes, classic, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chimes: return "Chimes (synthesized)"
        case .classic: return "Classic (system sounds)"
        case .off: return "Off"
        }
    }
}

/// Short synthesized cues plus a trackpad tap, so start, stop and done feel distinct without being noisy.
final class SoundDesign {
    enum Cue {
        case start, stop, done, cancel, error
    }

    static let shared = SoundDesign()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var idleStop: DispatchWorkItem?

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers[.start] = render([(660, 0, 0.07), (990, 0.055, 0.12)], volume: 0.16)
        buffers[.stop] = render([(880, 0, 0.07), (587, 0.05, 0.12)], volume: 0.14)
        buffers[.done] = render([(784, 0, 0.32), (988, 0.035, 0.3), (1319, 0.07, 0.28)], volume: 0.07)
        buffers[.cancel] = render([(440, 0, 0.12)], volume: 0.08)
        buffers[.error] = render([(233, 0, 0.12), (196, 0.11, 0.18)], volume: 0.14)
    }

    func play(_ cue: Cue, theme: SoundTheme) {
        haptic(cue)
        switch theme {
        case .off:
            return
        case .classic:
            let names: [Cue: (String, Float)] = [.start: ("Tink", 0.5), .stop: ("Pop", 0.5), .cancel: ("Funk", 0.25), .error: ("Basso", 0.4)]
            if let (name, volume) = names[cue], let sound = NSSound(named: NSSound.Name(name)) {
                sound.volume = volume
                sound.play()
            }
        case .chimes:
            guard let buffer = buffers[cue] else { return }
            if !engine.isRunning { try? engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !player.isPlaying { player.play() }
            // Don't keep an output engine running while idle.
            idleStop?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.player.stop()
                self?.engine.stop()
            }
            idleStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func haptic(_ cue: Cue) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = cue == .start || cue == .done ? .levelChange : .alignment
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Sine partials with a soft attack, exponential decay and a faint octave shimmer.
    private func render(_ notes: [(freq: Double, offset: Double, length: Double)], volume: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = notes.map { $0.offset + $0.length }.max() ?? 0.2
        let frames = AVAudioFrameCount(total * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { out[i] = 0 }
        for note in notes {
            let start = Int(note.offset * rate)
            let count = Int(note.length * rate)
            for n in 0..<count where start + n < Int(frames) {
                let t = Double(n) / rate
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 5.5 / note.length)
                let tone = sin(2 * .pi * note.freq * t) + 0.18 * sin(2 * .pi * note.freq * 2 * t)
                out[start + n] += Float(tone * attack * decay) * volume
            }
        }
        return buffer
    }
}
