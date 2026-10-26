import Foundation

/// The recognition models the menu can switch between. Models live under
/// ~/Library/Application Support/Unazc/models (scripts/fetch-deps.sh puts them there).
enum Engine: String, CaseIterable {
    case reazon
    case reazonJaEn
    case kotoba

    static let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Unazc/models")

    var title: String {
        switch self {
        case .reazon: return "ReazonSpeech（速度重視）"
        case .reazonJaEn: return "ReazonSpeech 日英"
        case .kotoba: return "Kotoba-Whisper v2（句読点あり）"
        }
    }

    /// A model directory (sherpa-onnx) or file (ggml).
    var location: URL {
        switch self {
        case .reazon: return Self.modelsRoot.appendingPathComponent("sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01")
        case .reazonJaEn: return Self.modelsRoot.appendingPathComponent("sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17")
        case .kotoba: return Self.modelsRoot.appendingPathComponent("kotoba-whisper-v2.0/ggml-kotoba-whisper-v2.0-q5_0.bin")
        }
    }

    var isInstalled: Bool {
        switch self {
        case .reazon, .reazonJaEn:
            return FileManager.default.fileExists(atPath: location.appendingPathComponent("tokens.txt").path)
        case .kotoba:
            return FileManager.default.fileExists(atPath: location.path)
        }
    }

    func make() throws -> SpeechRecognizer {
        switch self {
        case .reazon, .reazonJaEn: return try SherpaTransducerRecognizer(modelDir: location)
        case .kotoba: return try WhisperRecognizer(model: location)
        }
    }

    static var selected: Engine {
        get { UserDefaults.standard.string(forKey: "engine").flatMap(Engine.init) ?? .reazon }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "engine") }
    }
}
