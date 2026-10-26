import Foundation

/// Finds pauses in a recording so finished stretches can be recognized while the user is still
/// talking. Works on 20 ms frame RMS levels. It cuts the raw audio in the middle of a pause, so
/// no sample is ever dropped; when unsure it does not cut, and the audio is simply recognized later.
/// Whether a segment holds speech at all is left to `SpeechDetector`, not to loudness.
enum PauseCutter {
    static let frameSize = 320 // 20 ms at 16 kHz

    struct Cut {
        /// First frame of the next segment; the segment is [after, frame).
        let frame: Int
    }

    /// Below this a frame counts as pause: 15% of the speech level (90th percentile of the
    /// recording so far), capped at an absolute 0.01. nil when there is too little audio to judge.
    static func pauseThreshold(_ levels: [Float]) -> Float? {
        guard levels.count >= 50 else { return nil }
        let speech = levels.sorted()[levels.count * 9 / 10]
        // Mic delivering (near) silence: nothing to compare against.
        guard speech > 0.0005 else { return nil }
        return min(speech * 0.15, 0.01)
    }

    /// Spoken line breaks. Only a segment that is nothing but one of these (said between pauses)
    /// counts, so talking *about* 改行 inside a sentence is left alone.
    /// Said alone, ReazonSpeech writes 改行 as its homophone 開業 or as 会長, and drops 次の from
    /// 次の行 / 次の段落, so those outputs count too. The dictionary applies after joining and cannot
    /// stop a bare 開業 becoming a line break; turning spokenNewline off is the way out.
    static let newlineWords: [String: String] = [
        "改行": "\n", "かいぎょう": "\n", "開業": "\n", "会長": "\n",
        "次の行": "\n", "つぎのぎょう": "\n", "行": "\n",
        "次の段落": "\n\n", "つぎのだんらく": "\n\n", "新しい段落": "\n\n", "段落": "\n\n",
    ]
    static let punctuation: Set<Character> = ["、", "。", "，", "．", "？", "！", "?", "!", ",", "."]

    /// Joins the texts of consecutive segments. Each boundary is a pause of 0.4 s or more, which
    /// usually marks a clause, so it becomes 「、」 when `comma` is on. Empty segments (skipped as
    /// noise) add nothing, an existing trailing punctuation mark is kept, and no comma goes next to
    /// a line break.
    static func join(_ parts: [String], style: Options.TextStyle) -> String {
        join(parts, comma: style.pauseComma, newline: style.spokenNewline)
    }

    static func join(_ parts: [String], comma: Bool, newline: Bool) -> String {
        var out = ""
        for text in parts where !text.isEmpty {
            // Whisper-type models punctuate even a lone word (「改行。」).
            let bare = String(text.filter { !punctuation.contains($0) && !$0.isWhitespace })
            if newline, let breakText = newlineWords[bare] {
                if out.last == "、" { out.removeLast() }
                out += breakText
                continue
            }
            if comma, let last = out.last, !punctuation.contains(last), !last.isNewline { out += "、" }
            out += text
        }
        return out
    }

    /// Whether every 20 ms sub-frame of `tail` (the newest audio) is within `factor` of the noise
    /// floor (10th percentile of `levels`, at least 0.0005). Relative to the floor, so it holds for quiet and loud
    /// microphones alike; it catches a word that has just begun, which the VAD only confirms after
    /// about 0.1 s. False when there is too little audio to know the floor.
    static func isNearNoiseFloor(levels: [Float], tail: ArraySlice<Float>, factor: Float = 3) -> Bool {
        guard levels.count >= 25, !tail.isEmpty else { return false }
        // Never below -66 dBFS, so digital silence's tiny dither does not count as sound.
        let floor = max(levels.sorted()[levels.count / 10], 0.0005)
        var end = tail.endIndex
        while end > tail.startIndex {
            let start = max(end - frameSize, tail.startIndex)
            if rms(tail[start..<end]) > floor * factor { return false }
            end = start
        }
        return true
    }

    static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for x in slice { sum += x * x }
        return (sum / Float(slice.count)).squareRoot()
    }

    static func levels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - frameSize + 1, by: frameSize).map {
            rms(samples[$0..<$0 + frameSize])
        }
    }

    /// The pause the recording is in right now: where it began and how many 20 ms frames of silence
    /// so far, and how many frames of speech there were from `after` up to it. nil while speech is
    /// still going (or the levels cannot be judged yet). For replying at a pause before it is long
    /// enough to cut.
    static func trailingPause(levels: [Float], after: Int) -> (start: Int, silentFrames: Int, voicedFrames: Int)? {
        guard let threshold = pauseThreshold(levels), let last = levels.indices.last, levels[last] < threshold else { return nil }
        var start = last
        while start > after, levels[start - 1] < threshold { start -= 1 }
        let voiced = levels[min(after, start)..<start].filter { $0 >= threshold }.count
        return (start, levels.count - start, voiced)
    }

    /// The first pause of at least `minSilenceMs` that starts `minSegmentMs` or more after frame
    /// `after`. Silence is judged against the speech level of the whole recording so far (90th
    /// percentile), so it needs at least a second of audio before it trusts itself.
    static func findCut(levels: [Float], after: Int, minSilenceMs: Double = 400, minSegmentMs: Double = 1000) -> Cut? {
        guard let threshold = pauseThreshold(levels) else { return nil }
        let silenceFrames = Int(minSilenceMs / 20)
        let earliest = after + Int(minSegmentMs / 20)

        var runStart: Int?
        var i = after
        while i < levels.count {
            if levels[i] < threshold {
                if runStart == nil { runStart = i }
                if let start = runStart, i - start + 1 >= silenceFrames, start >= earliest {
                    return Cut(frame: start + silenceFrames / 2)
                }
            } else {
                runStart = nil
            }
            i += 1
        }
        return nil
    }
}
