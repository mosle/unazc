import Foundation

/// Behaviours that are a matter of taste, toggled from the menu (stored in defaults).
enum Options {
    /// A pause of 0.4 s or more becomes 「、」.
    static var pauseComma: Bool {
        get { UserDefaults.standard.object(forKey: "pauseComma") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pauseComma") }
    }

    /// Saying only 「改行」/「次の行」 (or 「次の段落」) between pauses inserts a line break.
    static var spokenNewline: Bool {
        get { UserDefaults.standard.object(forKey: "spokenNewline") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "spokenNewline") }
    }

    /// The options above that shape the text, which an app can set for itself (see `style(for:)`).
    enum TextOption: String, CaseIterable {
        case pauseComma, questionMark, spokenNewline

        var title: String {
            switch self {
            case .pauseComma: return "間で読点「、」を入れる"
            case .questionMark: return "語尾が上がったら「？」を付ける"
            case .spokenNewline: return "「改行」「次の行」とだけ言うと改行"
            }
        }

        /// The setting for every app without its own.
        var global: Bool {
            get {
                switch self {
                case .pauseComma: return Options.pauseComma
                case .questionMark: return Options.questionMark
                case .spokenNewline: return Options.spokenNewline
                }
            }
            nonmutating set {
                switch self {
                case .pauseComma: Options.pauseComma = newValue
                case .questionMark: Options.questionMark = newValue
                case .spokenNewline: Options.spokenNewline = newValue
                }
            }
        }
    }

    /// What the text options come to for one dictation, fixed when it starts.
    struct TextStyle: Equatable {
        var pauseComma: Bool
        var questionMark: Bool
        var spokenNewline: Bool
    }

    /// Per-app overrides, by bundle ID: an option missing for an app follows the global setting.
    private static let appOverridesKey = "appTextOverrides"
    private static var appOverrides: [String: [String: Bool]] {
        get { UserDefaults.standard.dictionary(forKey: appOverridesKey) as? [String: [String: Bool]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: appOverridesKey) }
    }

    /// Apps with at least one option of their own, sorted for display by the caller.
    static var appsWithOverrides: [String] { Array(appOverrides.keys) }

    static func override(_ option: TextOption, app: String) -> Bool? {
        appOverrides[app]?[option.rawValue]
    }

    /// nil removes the override; an app left with none is forgotten.
    static func setOverride(_ option: TextOption, app: String, _ value: Bool?) {
        var all = appOverrides
        var mine = all[app] ?? [:]
        mine[option.rawValue] = value
        all[app] = mine.isEmpty ? nil : mine
        appOverrides = all
    }

    static func removeOverrides(app: String) {
        var all = appOverrides
        all[app] = nil
        appOverrides = all
    }

    static func value(_ option: TextOption, app: String?) -> Bool {
        app.flatMap { override(option, app: $0) } ?? option.global
    }

    static func style(for app: String?) -> TextStyle {
        TextStyle(pauseComma: value(.pauseComma, app: app), questionMark: value(.questionMark, app: app),
                  spokenNewline: value(.spokenNewline, app: app))
    }

    /// How long recording continues after Fn is released, for audio still in flight and a last
    /// syllable cut short by an early release. Adds directly to latency when it runs.
    static let postRollChoices: [Double] = [0, 100, 150, 250, 400]
    static func postRollTitle(_ ms: Double) -> String {
        (ms == 0 ? "なし" : "\(Int(ms))ms") + (ms == 150 ? "（標準）" : "")
    }
    static var postRollMs: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: "postRollMs") as? Double, (0...1000).contains(v) else { return 150 }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: "postRollMs") }
    }

    /// Skip the post-roll when the voice detector hears that speech had already ended at release.
    static var skipPostRollWhenDone: Bool {
        get { UserDefaults.standard.object(forKey: "skipPostRollWhenDone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "skipPostRollWhenDone") }
    }

    /// How long the microphone stays open after a dictation, so the next one starts instantly and
    /// with the audio from just before the press. 0 closes it at once, a negative value never.
    /// Keeping it open shows the orange in-use indicator meanwhile.
    static let micKeepOpenChoices: [Double] = [0, 180, -1]
    static func micKeepOpenTitle(_ seconds: Double) -> String {
        switch seconds {
        case 0: return "開いておかない（毎回開く）"
        case ..<0: return "常に開いておく"
        case 180: return "3分（標準）"
        default: return seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60))分" : "\(Int(seconds))秒"
        }
    }
    static var micKeepOpenSeconds: Double {
        get { UserDefaults.standard.object(forKey: "micKeepOpenSeconds") as? Double ?? 180 }
        set { UserDefaults.standard.set(newValue, forKey: "micKeepOpenSeconds") }
    }

    /// Show the text recognized so far in a floating panel while Fn is held.
    static var liveText: Bool {
        get { UserDefaults.standard.object(forKey: "liveText") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveText") }
    }

    /// Append 「？」 when a stretch ends with rising intonation (see Intonation).
    static var questionMark: Bool {
        get { UserDefaults.standard.object(forKey: "questionMark") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "questionMark") }
    }

    /// Pause music or video that is playing while dictating, and resume it after (see MediaPauser).
    static var pauseMedia: Bool {
        get { UserDefaults.standard.bool(forKey: "pauseMedia") }
        set { UserDefaults.standard.set(newValue, forKey: "pauseMedia") }
    }

    /// A short 「うん」 in headphones at pauses while dictating (see Backchannel).
    static var backchannel: Bool {
        get { UserDefaults.standard.bool(forKey: "backchannel") }
        set { UserDefaults.standard.set(newValue, forKey: "backchannel") }
    }

    /// 0...1, relative to the system volume.
    static var backchannelVolume: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: "backchannelVolume") as? Double, (0...1).contains(v) else { return 0.6 }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: "backchannelVolume") }
    }

    /// The call screen (see CallWindow).
    static var callWindow: Bool {
        get { UserDefaults.standard.bool(forKey: "callWindow") }
        set { UserDefaults.standard.set(newValue, forKey: "callWindow") }
    }

    /// Keep the call screen above other windows, on every Space.
    static var callOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "callOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "callOnTop") }
    }

    /// The call screen as a single slim line instead of the full card.
    static var callCompact: Bool {
        get { UserDefaults.standard.bool(forKey: "callCompact") }
        set { UserDefaults.standard.set(newValue, forKey: "callCompact") }
    }

    static let callOpacityChoices: [Double] = [1, 0.85, 0.7, 0.5, 0.3]
    static var callOpacity: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: "callOpacity") as? Double, (0.1...1).contains(v) else { return 1 }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: "callOpacity") }
    }

    /// How Fn starts and stops a recording.
    enum RecordKeyMode: String, CaseIterable {
        /// Records while Fn is held.
        case hold
        /// One press starts, the next stops.
        case toggle
        /// A short tap starts and the next press stops; a longer hold records while held.
        case both

        /// A press shorter than this latches in `both`. Close to the shortest hold the app keeps
        /// (presses below that were dropped anyway), so few real holds latch by accident.
        static let tapMs: Double = 300

        var title: String {
            switch self {
            case .hold: return "押している間だけ（標準）"
            case .toggle: return "1回押して開始・もう1回で終了"
            case .both: return "両方（短く押すと開始・終了、長押しは押している間）"
            }
        }

        /// Whether Fn released after `heldMs` keeps recording until the next press.
        func latches(heldMs: Double) -> Bool {
            switch self {
            case .hold: return false
            case .toggle: return true
            case .both: return heldMs < Self.tapMs
            }
        }
    }
    static var recordKeyMode: RecordKeyMode {
        get { UserDefaults.standard.string(forKey: "recordKeyMode").flatMap(RecordKeyMode.init) ?? .hold }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recordKeyMode") }
    }

    /// Holding Shift when the recording ends (Fn released, or the stopping press in toggle mode)
    /// presses Return after the paste. Off by default: an accidental send is worse than a missing one.
    static var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSend") }
        set { UserDefaults.standard.set(newValue, forKey: "autoSend") }
    }
}
