import Accelerate
import Foundation

/// Rising end intonation, for adding 「？」. The recognizer gives no punctuation, and a Japanese
/// question is mostly marked by the pitch going up on the last mora. Leans towards adding one:
/// deleting a stray 「？」 is one keystroke, inserting a missing one means moving the cursor.
enum Intonation {
    private static let rate: Double = 16_000
    private static let frame = 512 // 32 ms analysis window
    private static let hop = 160 // 10 ms
    private static let minLag = 40 // 400 Hz
    private static let maxLag = 228 // ~70 Hz
    /// YIN threshold on the cumulative mean normalized difference; lower means more periodic.
    /// Far above the paper's 0.1-0.15 because of real microphone noise: 0.3 left too few frames
    /// voiced to estimate the end, 0.6 let octave errors in.
    private static let voicedThreshold: Float = 0.45

    /// Pitch (Hz) of each 10 ms step, nil where unvoiced. YIN (de Cheveigné & Kawahara 2002)
    /// without the parabolic refinement, which semitone-level decisions do not need.
    static func pitchTrack(_ samples: ArraySlice<Float>) -> [Double?] {
        let x = Array(samples)
        guard x.count >= frame + maxLag else { return [] }
        var track: [Double?] = []
        var diff = [Float](repeating: 0, count: maxLag + 1)
        var start = 0
        while start + frame + maxLag <= x.count {
            x.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress! + start
                var energy0: Float = 0
                vDSP_dotpr(base, 1, base, 1, &energy0, vDSP_Length(frame))
                for lag in 1...maxLag {
                    var energyLag: Float = 0, cross: Float = 0
                    vDSP_dotpr(base + lag, 1, base + lag, 1, &energyLag, vDSP_Length(frame))
                    vDSP_dotpr(base, 1, base + lag, 1, &cross, vDSP_Length(frame))
                    diff[lag] = energy0 + energyLag - 2 * cross
                }
            }
            // Cumulative mean normalization, then the first dip under the threshold.
            var running: Float = 0
            var best: Int?
            for lag in 1...maxLag {
                running += diff[lag]
                let normalized = running > 0 ? diff[lag] * Float(lag) / running : 1
                if lag >= 2, normalized < voicedThreshold {
                    // Walk down to the bottom of this dip.
                    var l = lag
                    while l < maxLag, diff[l + 1] < diff[l] { l += 1 }
                    // A period shorter than the range (over 400 Hz) would otherwise be read as
                    // its double; treat the frame as unknown rather than an octave off.
                    if l >= minLag { best = l }
                    break
                }
            }
            track.append(best.map { rate / Double($0) })
            start += hop
        }
        return track
    }

    /// How far (semitones) the pitch of the last voiced 120 ms is above the 120-500 ms before it.
    /// nil when there is too little voiced speech near the end to tell.
    static func endRise(_ samples: [Float]) -> Double? {
        let track = pitchTrack(samples.suffix(32_000)[...])
        return endRise(track: track)
    }

    /// No octave-error filter: real question rises measured 5-8 semitones, and one dropped them.
    static func endRise(track: [Double?]) -> Double? {
        // End of speech: the last frame with at least 3 of the 5 around it voiced, so a stray
        // voiced frame in trailing noise or breath is not taken for the last mora.
        func voiced(_ i: Int) -> Bool { i >= 0 && i < track.count && track[i] != nil }
        guard let last = track.indices.last(where: { i in voiced(i) && (i - 2...i + 2).filter(voiced).count >= 3 }) else {
            return nil
        }
        func median(_ range: ClosedRange<Int>) -> Double? {
            let values = track[max(0, range.lowerBound)...max(0, range.upperBound)].compactMap { $0 }.sorted()
            return values.count >= 3 ? values[values.count / 2] : nil
        }
        guard let end = median((last - 11)...last), let before = median((last - 50)...(last - 12)) else { return nil }
        return 12 * log2(end / before)
    }

    /// Sentence endings that are usually questions; with one, a smaller rise is enough.
    private static let questionEndings = ["か", "の", "かな", "かい", "よね", "でしょ", "でしょう", "だろ", "だろう", "っけ"]

    /// Semitones of rise needed: lenient on purpose (see the type comment).
    static let riseNeeded = 1.0
    static let riseNeededWithEnding = 0.5

    /// Whether `audio` ends rising enough for a question, `text` being what was said; false when it
    /// cannot tell. Quiet: for choosing a reply, not for the 「？」 option.
    static func soundsLikeQuestion(_ text: String, audio: [Float]) -> Bool {
        guard let rise = endRise(audio) else { return false }
        return rise >= (questionEndings.contains { text.hasSuffix($0) } ? riseNeededWithEnding : riseNeeded)
    }

    /// `text` with 「？」 appended when its audio ends rising and `enabled`. Text that already ends in
    /// punctuation (Whisper punctuates itself) or is empty is left alone.
    static func markQuestion(_ text: String, audio: [Float], enabled: Bool) -> String {
        guard enabled, let lastChar = text.last, !PauseCutter.punctuation.contains(lastChar) else { return text }
        let track = pitchTrack(audio.suffix(32_000)[...])
        guard let rise = endRise(track: track) else {
            Log.info("intonation unknown: \(track.compactMap { $0 }.count)/\(track.count) frames voiced")
            return text
        }
        let ending = questionEndings.contains { text.hasSuffix($0) }
        let question = rise >= (ending ? riseNeededWithEnding : riseNeeded)
        Log.info(String(format: "intonation rise=%+.1fst ending=%@ question=%@", rise, ending ? "yes" : "no", question ? "yes" : "no"))
        return question ? text + "？" : text
    }
}
