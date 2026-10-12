import Accelerate
import Foundation

/// Tells the other people on a call apart by how they sound, on this Mac. Each stretch of the "Them" track gets a
/// voice fingerprint (the average and spread of its MFCCs, the standard speech features), and similar fingerprints
/// are grouped. Good at telling a few distinct voices apart; when it isn't sure, everything stays "Them".
enum Diarization {
    static let sampleRate = 16_000.0
    private static let fftSize = 512, frameLength = 400, hop = 160, melBands = 26, coefficients = 12

    /// Speaker number (0, 1, 2… in order of first appearance) for each segment, or nil if it all sounds like one voice.
    /// `starts` are segment start times in seconds, in order; each segment runs until the next one starts.
    static func speakers(samples: [Float], starts: [Double], threshold: Float = 4.6, maxSpeakers: Int = 6) -> [Int]? {
        guard starts.count >= 2 else { return nil }
        let total = Double(samples.count) / sampleRate
        var features: [[Float]?] = []
        for (i, start) in starts.enumerated() {
            let end = min(i + 1 < starts.count ? starts[i + 1] : total, start + 30)
            let a = max(0, Int(start * sampleRate)), b = min(samples.count, Int(end * sampleRate))
            features.append(b - a > Int(0.8 * sampleRate) ? fingerprint(samples[a..<b]) : nil)
        }
        let known = features.enumerated().compactMap { i, f in f.map { (i, $0) } }
        guard known.count >= 2 else { return nil }
        // Distance on the average voice character (MFCC means). Absolute, not relative to this call, so one person never gets split in two.
        let labels = cluster(known.map { Array($0.1.prefix(coefficients)) }, threshold: threshold, maxClusters: maxSpeakers)
        guard Set(labels).count > 1 else { return nil }

        // Short segments take the speaker of the nearest fingerprinted segment before them (or after, at the start).
        var assigned = [Int?](repeating: nil, count: starts.count)
        for (k, (i, _)) in known.enumerated() { assigned[i] = labels[k] }
        var last: Int?
        for i in assigned.indices {
            if let a = assigned[i] { last = a } else { assigned[i] = last }
        }
        let firstKnown = assigned.first(where: { $0 != nil }) ?? 0
        let filled = assigned.map { $0 ?? firstKnown ?? 0 }
        // Number speakers in order of first appearance.
        var order: [Int: Int] = [:]
        return filled.map { label in
            if let n = order[label] { return n }
            order[label] = order.count
            return order[label]!
        }
    }

    // MARK: Fingerprints

    /// Mean and standard deviation of MFCC 1–12 over the loudest frames: 24 numbers that describe a voice's timbre.
    static func fingerprint(_ audio: ArraySlice<Float>) -> [Float]? {
        let x = Array(audio)
        let frames = (x.count - frameLength) / hop
        guard frames >= 40 else { return nil }
        var energies = [Float](repeating: 0, count: frames)
        var mfccs = [[Float]](repeating: [], count: frames)
        for f in 0..<frames {
            let frame = Array(x[(f * hop)..<(f * hop + frameLength)])
            energies[f] = vDSP.sumOfSquares(frame) / Float(frameLength)
            mfccs[f] = mfcc(frame)
        }
        // Voiced frames: the top 60% by energy, so pauses and breaths don't blur the fingerprint.
        let cutoff = energies.sorted()[Int(Double(frames) * 0.4)]
        let voiced = mfccs.indices.filter { energies[$0] >= cutoff && energies[$0] > 1e-7 }.map { mfccs[$0] }
        guard voiced.count >= 25 else { return nil }
        var mean = [Float](repeating: 0, count: coefficients), sd = mean
        for c in 0..<coefficients {
            let column = voiced.map { $0[c] }
            mean[c] = vDSP.mean(column)
            sd[c] = sqrt(vDSP.meanSquare(vDSP.add(-mean[c], column)))
        }
        return mean + sd
    }

    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frameLength, isHalfWindow: false)
    private static let fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!   // 2^9 = 512
    private static let filterbank: [[Float]] = {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let bins = fftSize / 2
        let lo = mel(80), hi = mel(7_600)
        let points = (0...(melBands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(melBands + 1)) }
        let idx = points.map { Int(($0 / (sampleRate / 2)) * Double(bins)) }
        return (1...melBands).map { m in
            var f = [Float](repeating: 0, count: bins)
            for k in idx[m - 1]..<idx[m] where idx[m] > idx[m - 1] { f[k] = Float(k - idx[m - 1]) / Float(idx[m] - idx[m - 1]) }
            for k in idx[m]..<idx[m + 1] where idx[m + 1] > idx[m] { f[k] = Float(idx[m + 1] - k) / Float(idx[m + 1] - idx[m]) }
            return f
        }
    }()

    private static func mfcc(_ frame: [Float]) -> [Float] {
        var padded = vDSP.multiply(frame, window) + [Float](repeating: 0, count: fftSize - frameLength)
        var real = [Float](repeating: 0, count: fftSize / 2), imag = real
        var power = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                padded.withUnsafeMutableBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }
        power[0] = real[0] * real[0]   // the packed Nyquist term isn't part of bin 0
        let logMel = filterbank.map { log(max(1e-10, vDSP.dot($0, power))) }
        // DCT-II, keeping coefficients 1…12 (coefficient 0 is just loudness).
        return (1...coefficients).map { k in
            var sum: Float = 0
            for (m, v) in logMel.enumerated() { sum += v * cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(melBands)) }
            return sum
        }
    }

    // MARK: Clustering

    /// Each dimension scaled to zero mean and unit variance across segments, so no single coefficient dominates.
    static func normalized(_ rows: [[Float]]) -> [[Float]] {
        guard let width = rows.first?.count else { return rows }
        var out = rows
        for d in 0..<width {
            let column = rows.map { $0[d] }
            let mean = vDSP.mean(column)
            let sd = max(1e-6, sqrt(vDSP.meanSquare(vDSP.add(-mean, column))))
            for r in out.indices { out[r][d] = (rows[r][d] - mean) / sd }
        }
        return out
    }

    /// Average-linkage agglomerative clustering on RMS distance: keep merging the two closest groups until
    /// the closest pair is further apart than `threshold`. Lance–Williams updates keep long meetings fast.
    static func cluster(_ rows: [[Float]], threshold: Float, maxClusters: Int) -> [Int] {
        let n = rows.count
        guard n > 1 else { return [Int](repeating: 0, count: n) }
        var d = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in (i + 1)..<n {
            let v = sqrt(vDSP.distanceSquared(rows[i], rows[j]) / Float(max(1, rows[i].count)))
            d[i][j] = v; d[j][i] = v
        } }
        var alive = Set(0..<n)
        var size = [Int](repeating: 1, count: n)
        var parent = Array(0..<n)
        while alive.count > 1 {
            var best = (Float.infinity, 0, 0)
            let ids = alive.sorted()
            for (x, a) in ids.enumerated() { for b in ids[(x + 1)...] where d[a][b] < best.0 { best = (d[a][b], a, b) } }
            if best.0 > threshold, alive.count <= maxClusters { break }
            let (_, a, b) = best
            for k in alive where k != a && k != b {
                let v = (Float(size[a]) * d[a][k] + Float(size[b]) * d[b][k]) / Float(size[a] + size[b])
                d[a][k] = v; d[k][a] = v
            }
            size[a] += size[b]
            alive.remove(b)
            for i in 0..<n where parent[i] == b { parent[i] = a }
        }
        let roots = alive.sorted()
        return (0..<n).map { i in roots.firstIndex(of: parent[i]) ?? 0 }
    }
}

/// Puts names to "Speaker 1", "Speaker 2"… when the conversation makes them clear ("Hi, I'm Priya", "Thanks, Rahul").
enum SpeakerNames {
    static func resolve(transcript: String, labels: [String], settings: AppSettings) async -> [String: String] {
        guard !labels.isEmpty else { return [:] }
        let instructions = """
        You read the start of a meeting transcript. Some participants are labelled \(labels.joined(separator: ", ")).
        For each label, give that person's first name only if the transcript makes it clear: they introduce themselves ("I'm Priya", "this is Rahul"), or someone addresses them by name right before they reply.
        Reply with JSON only, like {"Speaker 1": "Priya"}. Leave out any label you're not sure about. Never guess.
        """
        let prompt = String(transcript.prefix(6_000))
        let reply: String?
        if settings.canUseCloud {
            reply = try? await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: 0)
        } else if AppleModel.isAvailable {
            reply = try? await AppleModel.respond(instructions: instructions, prompt: prompt)
        } else {
            reply = nil
        }
        guard let reply, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let data = String(reply[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for label in labels {
            guard let name = (json[label] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name.count <= 30,
                  name.first?.isUppercase == true, !names.values.contains(name), name != "You" else { continue }
            names[label] = name
        }
        return names
    }
}
