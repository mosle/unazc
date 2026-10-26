import CSherpaOnnx
import Foundation

/// Speech recognition engines are swappable so ReazonSpeech and Kotoba-Whisper can be compared.
protocol SpeechRecognizer: AnyObject {
    var name: String { get }
    /// 16 kHz mono float samples in [-1, 1]. Throws when the engine fails, as opposed to hearing nothing.
    func recognize(_ samples: [Float]) throws -> String
    /// Whether a short clip decodes in well under 0.1 s, so the live preview may run on it. A
    /// running preview cannot be interrupted and delays the final recognition by its remainder.
    var previewIsCheap: Bool { get }
}

extension SpeechRecognizer {
    /// A failure is logged and inserts nothing.
    func transcribe(_ samples: [Float]) -> String {
        do {
            return try recognize(samples)
        } catch {
            Log.info("\(name) failed: \(error)")
            return ""
        }
    }

    /// The first inference is slow; run one on silence at load so the user never pays for it.
    /// Also proves the model actually runs before it replaces a working one.
    func warmUp() throws {
        let t = nowMs()
        _ = try recognize([Float](repeating: 0, count: 16_000))
        Log.info("warmup \(name) \(Int(nowMs() - t))ms")
    }
}

/// sherpa-onnx aborts the whole process (an uncaught C++ exception) when a model file exists but
/// cannot be opened, e.g. when macOS privacy protection denies the folder it is in. So every model
/// file is opened here first, and the failure becomes an ordinary error.
func requireReadable(_ path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else { throw RecognizerError.missingFile(path) }
    guard let handle = FileHandle(forReadingAtPath: path) else { throw RecognizerError.unreadable(path) }
    handle.closeFile()
}

enum RecognizerError: Error, CustomStringConvertible {
    case missingFile(String)
    case unreadable(String)
    case createFailed
    case inferenceFailed(Int32)

    var description: String {
        switch self {
        case .missingFile(let f): return "model file not found: \(f)"
        case .unreadable(let f): return "model file not readable (folder access denied?): \(f)"
        case .createFailed: return "failed to create recognizer"
        case .inferenceFailed(let code): return "inference failed (\(code))"
        }
    }
}

/// ReazonSpeech (k2 zipformer transducer) via sherpa-onnx.
final class SherpaTransducerRecognizer: SpeechRecognizer {
    let name: String
    let previewIsCheap = true
    private let recognizer: OpaquePointer
    /// 0.4 s; UNAZC_TAIL_PAD overrides it (0 disables).
    var tailPaddingSamples: Int = {
        guard let v = Int(ProcessInfo.processInfo.environment["UNAZC_TAIL_PAD"] ?? ""), (0...32_000).contains(v) else {
            return 6_400
        }
        return v
    }()

    init(modelDir: URL, preferInt8: Bool = true, numThreads: Int32 = 4) throws {
        name = "sherpa:\(modelDir.lastPathComponent)"
        func pick(_ part: String) throws -> String {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
            let candidates = files.filter { $0.hasPrefix(part) && $0.hasSuffix(".onnx") }.sorted()
            let int8 = candidates.first { $0.contains(".int8.") }
            let fp = candidates.first { !$0.contains(".int8.") }
            guard let chosen = (preferInt8 ? int8 ?? fp : fp ?? int8) else {
                throw RecognizerError.missingFile("\(modelDir.path)/\(part)*.onnx")
            }
            let path = modelDir.appendingPathComponent(chosen).path
            try requireReadable(path)
            return path
        }
        let encoder = try pick("encoder")
        let decoder = try pick("decoder")
        let joiner = try pick("joiner")
        let tokens = modelDir.appendingPathComponent("tokens.txt").path
        try requireReadable(tokens)
        Log.info("model encoder=\((encoder as NSString).lastPathComponent)")

        // The C API keeps the pointers only during creation, so strdup'd strings are freed afterwards.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(encoder)
        config.model_config.transducer.decoder = c(decoder)
        config.model_config.transducer.joiner = c(joiner)
        config.model_config.tokens = c(tokens)
        config.model_config.num_threads = numThreads
        config.model_config.provider = c("cpu")
        config.model_config.model_type = c("transducer")
        config.decoding_method = c("greedy_search")
        config.max_active_paths = 4

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else { throw RecognizerError.createFailed }
        recognizer = r
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    func recognize(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw RecognizerError.createFailed }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        // Without trailing silence the transducer often drops the last syllable when the key is
        // released right as speech ends. Padding costs a few ms of compute, not wall time.
        let padded = samples + [Float](repeating: 0, count: tailPaddingSamples)
        padded.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, 16_000, $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) } ?? ""
    }
}

/// How the live panel previews the stretch still being spoken, chosen from this Mac's measured
/// recognition speed. A preview cannot be interrupted, so one running at release delays the final
/// pass by its remainder; on a slow Mac previews get rarer and shorter, or stop.
struct PreviewPolicy: CustomStringConvertible {
    /// Ticks of the 100 ms segment timer between previews; nil means no preview of the open stretch
    /// (finished stretches still show).
    let everyTicks: Int?
    /// Longest open stretch previewed, in samples.
    let maxSamples: Int
    /// Decode cost: fixed part plus per second of audio.
    let fixedMs: Double
    let msPerSecond: Double

    static let off = PreviewPolicy(everyTicks: nil, maxSamples: 0, fixedMs: 0, msPerSecond: 0)

    /// Keep a preview's own cost, and so the worst added delay at release, under this.
    static let budgetMs = 100.0

    init(everyTicks: Int?, maxSamples: Int, fixedMs: Double, msPerSecond: Double) {
        self.everyTicks = everyTicks
        self.maxSamples = maxSamples
        self.fixedMs = fixedMs
        self.msPerSecond = msPerSecond
    }

    init(fixedMs: Double, msPerSecond: Double, cheap: Bool) {
        let perSecond = max(msPerSecond, 1)
        let maxSeconds = min(8, (Self.budgetMs - fixedMs) / perSecond)
        guard cheap, maxSeconds >= 1.5 else {
            self = PreviewPolicy(everyTicks: nil, maxSamples: 0, fixedMs: fixedMs, msPerSecond: msPerSecond)
            return
        }
        // Every 0.3 s on a fast Mac; slower ones space previews out so that a preview of a
        // typical 3 s stretch takes at most about a third of the time between them.
        let typicalMs = fixedMs + 3 * perSecond
        let ticks = max(3, Int((typicalMs * 3 / 100).rounded(.up)))
        self = PreviewPolicy(everyTicks: ticks, maxSamples: Int(maxSeconds * 16_000), fixedMs: fixedMs, msPerSecond: msPerSecond)
    }

    /// Times 1 s and 5 s decodes (after warm-up, on the recognizer's queue): the difference gives
    /// the per-second cost, the rest is fixed overhead. Best of two runs each, to skip hiccups.
    /// Engines that are never previewed are not timed unless `always` (for the CLI).
    static func measure(_ recognizer: SpeechRecognizer, always: Bool = false) -> PreviewPolicy {
        guard always || recognizer.previewIsCheap else { return .off }
        func best(_ seconds: Int) -> Double? {
            var times: [Double] = []
            for _ in 0..<2 {
                let t = nowMs()
                guard (try? recognizer.recognize([Float](repeating: 0, count: seconds * 16_000))) != nil else {
                    Log.info("live preview: timing decode failed")
                    return nil
                }
                times.append(nowMs() - t)
            }
            return times.min()
        }
        guard let one = best(1) else { return .off }
        // Already over budget at 1 s: previews would be off whatever the 5 s run says.
        if !always, one >= budgetMs { return PreviewPolicy(fixedMs: one, msPerSecond: 0, cheap: false) }
        guard let five = best(5) else { return .off }
        let perSecond = max((five - one) / 4, 0)
        return PreviewPolicy(fixedMs: max(one - perSecond, 0), msPerSecond: perSecond, cheap: recognizer.previewIsCheap)
    }

    var description: String {
        let cost = String(format: "%.0fms + %.0fms per audio second", fixedMs, msPerSecond)
        guard let everyTicks else { return "off (\(cost))" }
        return String(format: "every %dms, up to %.1fs (%@)", everyTicks * 100, Double(maxSamples) / 16_000, cost)
    }
}
