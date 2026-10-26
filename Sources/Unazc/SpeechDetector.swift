import CSherpaOnnx
import Foundation

/// Silero VAD, used only to decide whether a stretch of audio holds any speech before it is sent
/// to the recognizer: on pure room noise the recognizer invents a syllable, and a loudness
/// threshold cannot tell quiet speech from noise. Not thread-safe; use from one queue.
final class SpeechDetector {
    private let vad: OpaquePointer
    private static let window = 512 // Silero expects 512-sample windows at 16 kHz
    /// `minSilence` for judging end of speech at release: short, so letting go ~0.1-0.2 s after the
    /// last word already counts as finished.
    static let tailMinSilence: Float = 0.1

    init(model: URL, minSilence: Float = 0.25) throws {
        try requireReadable(model.path)
        let path = strdup(model.path)!
        let provider = strdup("cpu")!
        defer { free(path); free(provider) }
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = UnsafePointer(path)
        // Lower than the default 0.5: missing quiet speech is worse than recognizing some noise.
        config.silero_vad.threshold = 0.3
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = 0.1
        config.silero_vad.window_size = Int32(Self.window)
        config.silero_vad.max_speech_duration = 30
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = UnsafePointer(provider)
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 60) else {
            throw RecognizerError.createFailed
        }
        self.vad = vad
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    /// Whether the speaker is still talking at the very end of `samples`. Fed whole windows ending
    /// exactly at the last sample; false means the last speech ended at least `minSilence` earlier,
    /// or there was none.
    func isSpeaking(atEndOf samples: [Float]) -> Bool {
        SherpaOnnxVoiceActivityDetectorReset(vad)
        defer { SherpaOnnxVoiceActivityDetectorReset(vad) }
        let start = samples.count % Self.window
        samples.withUnsafeBufferPointer { buf in
            var i = start
            while i + Self.window <= buf.count {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress! + i, Int32(Self.window))
                i += Self.window
            }
        }
        return SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
    }

    func containsSpeech(_ samples: [Float]) -> Bool {
        SherpaOnnxVoiceActivityDetectorReset(vad)
        defer { SherpaOnnxVoiceActivityDetectorReset(vad) }
        var found = false
        // Silero only runs on whole windows; a partial last window would stay buffered unjudged.
        // So pad with zeros to a window boundary, plus two windows so speech in the last one is
        // still seen; much more padding makes the noise-to-zero edge itself read as speech.
        let padTo = (samples.count + Self.window - 1) / Self.window * Self.window + 2 * Self.window
        let padded = samples + [Float](repeating: 0, count: padTo - samples.count)
        padded.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count, !found {
                let n = min(Self.window, buf.count - i)
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress! + i, Int32(n))
                found = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
                    || SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0
                i += n
            }
        }
        if !found {
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            found = SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0
        }
        return found
    }
}
