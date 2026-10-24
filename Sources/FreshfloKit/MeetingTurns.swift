import Foundation

/// Splits a meeting track into real turns before it's transcribed.
///
/// The other side of a call is mostly silence (they're quiet while you talk). Sent as one long file, Whisper glues
/// separate turns into one line, drifts its timestamps, and invents repeats on the silence, so lines come out in the
/// wrong order and voices can't be told apart. Instead: find where speech is, squeeze the silences down to a short
/// pause (keeping a map back to real time), transcribe once, then use each word's time to put the text back into
/// the turn it was spoken in, at the moment it was spoken.
enum MeetingTurns {
    static let rate = 16_000

    /// Where someone is talking, in samples.
    struct Region: Equatable {
        var start: Int
        var end: Int
    }

    /// A stretch of the squeezed audio and where it really was in the meeting (seconds).
    struct Span: Equatable {
        var squeezedStart: Double
        var originalStart: Double
        var duration: Double
    }

    struct Turn: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Finding speech

    /// Speech regions by loudness against the track's own noise floor. Pauses shorter than `bridge` stay inside
    /// one turn (kept short: two people handing over quickly must not share a turn; one person split in two is
    /// merged back later); anything shorter than `minimum` (a cough, a click) is dropped.
    static func speechRegions(_ samples: [Float], bridge: Double = 0.4, pad: Double = 0.15, minimum: Double = 0.35) -> [Region] {
        let frame = rate * 3 / 100   // 30 ms
        guard samples.count >= frame else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for k in i..<(i + frame) { sum += samples[k] * samples[k] }
            levels.append(sqrt(sum / Float(frame)))
            i += frame
        }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 5]
        let threshold = max(floor * 3, 0.006)
        var regions: [Region] = []
        var current: Region?
        let bridgeFrames = Int(bridge * Double(rate)) / frame
        var quiet = 0
        for (f, level) in levels.enumerated() {
            if level >= threshold {
                if current == nil { current = Region(start: f * frame, end: (f + 1) * frame) }
                current?.end = (f + 1) * frame
                quiet = 0
            } else if let c = current {
                quiet += 1
                if quiet > bridgeFrames { regions.append(c); current = nil; quiet = 0 }
            }
        }
        if let current { regions.append(current) }
        let padding = Int(pad * Double(rate)), shortest = Int(minimum * Double(rate))
        return regions
            .filter { $0.end - $0.start >= shortest }
            .map { Region(start: max(0, $0.start - padding), end: min(samples.count, $0.end + padding)) }
    }

    // MARK: Squeezing out the silence

    /// The regions back to back with a short pause between them, and where each one came from.
    static func squeeze(_ samples: [Float], regions: [Region], gap: Double = 0.8) -> (audio: [Float], spans: [Span]) {
        var audio: [Float] = []
        var spans: [Span] = []
        let silence = [Float](repeating: 0, count: Int(gap * Double(rate)))
        for r in regions {
            if !audio.isEmpty { audio += silence }
            spans.append(Span(squeezedStart: Double(audio.count) / Double(rate), originalStart: Double(r.start) / Double(rate),
                              duration: Double(r.end - r.start) / Double(rate)))
            audio += samples[r.start..<r.end]
        }
        return (audio, spans)
    }

    /// Which span a moment in the squeezed audio belongs to (the nearest one when it falls in a pause).
    static func span(at t: Double, in spans: [Span]) -> Int? {
        guard !spans.isEmpty else { return nil }
        if let i = spans.firstIndex(where: { t >= $0.squeezedStart - 0.05 && t < $0.squeezedStart + $0.duration + 0.05 }) { return i }
        return spans.indices.min { abs(spans[$0].squeezedStart - t) < abs(spans[$1].squeezedStart - t) }
    }

    // MARK: Putting text back into turns

    /// Splits Whisper's segments at the turn boundaries using its word times, and gives each piece the real time
    /// its turn started. Without word times, each segment goes to the turn its start falls in.
    static func turns(segments: [Transcriber.TimedSegment], words: [Transcriber.Word], spans: [Span]) -> [Turn] {
        var pieces: [(span: Int, text: String)] = []
        for seg in segments {
            let tokens = seg.text.split(separator: " ").map(String.init)
            let inside = words.filter { $0.start >= seg.start - 0.05 && $0.start < seg.end + 0.05 }
            if !inside.isEmpty, inside.count == tokens.count {
                // One token per word: cut the segment wherever the words move to another turn.
                for (token, word) in zip(tokens, inside) {
                    guard let s = span(at: word.start, in: spans) else { continue }
                    if let last = pieces.last, last.span == s { pieces[pieces.count - 1].text += " " + token } else { pieces.append((s, token)) }
                }
            } else if let s = span(at: seg.start, in: spans) {
                if let last = pieces.last, last.span == s { pieces[pieces.count - 1].text += " " + seg.text } else { pieces.append((s, seg.text)) }
            }
        }
        return pieces.map { Turn(start: spans[$0.span].originalStart, end: spans[$0.span].originalStart + spans[$0.span].duration,
                                 text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
    }
}
