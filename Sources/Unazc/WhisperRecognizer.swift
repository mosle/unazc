import Foundation
import whisper

/// Kotoba-Whisper (or any ggml Whisper model) via whisper.cpp on Metal. Unlike ReazonSpeech it
/// emits punctuation itself.
final class WhisperRecognizer: SpeechRecognizer {
    let name: String
    /// Whisper always encodes a 30 s window (~0.4 s), too slow to run alongside the final pass.
    let previewIsCheap = false
    private let context: OpaquePointer
    private let numThreads: Int32
    /// whisper_full reads it on every call, so it lives as long as the recognizer.
    private let language = strdup("ja")!

    init(model: URL, numThreads: Int32 = 4) throws {
        try requireReadable(model.path)
        name = "whisper:\(model.deletingPathExtension().lastPathComponent)"
        self.numThreads = numThreads
        // whisper.cpp logs every load step to stderr; keep only our own log.
        whisper_log_set({ _, _, _ in }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(model.path, params) else {
            free(language)
            throw RecognizerError.createFailed
        }
        context = ctx
    }

    deinit {
        whisper_free(context)
        free(language)
    }

    func recognize(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = UnsafePointer(language)
        params.translate = false
        params.n_threads = numThreads
        params.no_context = true
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_nst = true
        // No temperature fallback: a retry can multiply the time, and latency matters more here.
        params.temperature_inc = 0
        // Not audio_ctx (a shorter window): 2-3x faster, but audio cut mid-word comes back as
        // repeated phrases or a lone "!".
        let status = samples.withUnsafeBufferPointer {
            whisper_full(context, params, $0.baseAddress, Int32($0.count))
        }
        guard status == 0 else { throw RecognizerError.inferenceFailed(status) }
        return (0..<whisper_full_n_segments(context)).compactMap { i in
            whisper_full_get_segment_text(context, i).map { String(cString: $0) }
        }.joined().trimmingCharacters(in: .whitespaces)
    }
}
