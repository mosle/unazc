import ApplicationServices
import Foundation

/// The most recent dictation, for Fn+V (paste it again), Fn+Z (remove it) and Fn+R (recognize its
/// audio again with another model and put that in its place). Main thread.
struct LastDictation {
    /// Counts dictations, so a slow re-recognition or paste can tell it is still about this one.
    let id: Int
    var text: String
    /// What was said, as recognized and fixed by the dictionary: `text` unless a snippet replaced
    /// it. Fn+D starts from this, since the dictionary applies before snippets.
    var recognized: String
    let audio: [Float]
    /// The text options it was made with, so a re-recognition comes out the same way.
    let style: Options.TextStyle
    /// The model that produced `text`; nil if unknown.
    var engine: Engine?
    /// The paste (AppController's count of pastes) that put `text` at the cursor, once the app
    /// has read it; nil while it is not known to be there.
    var paste: Int?
    /// Removed with Fn+Z, so a re-recognition just pastes its result.
    var removed = false
    /// The frontmost app when it was pasted.
    var app: pid_t?
    /// HotkeyMonitor's input generation when it was pasted.
    var generation = 0
    /// Return was pressed after it, so it has been sent and cannot be taken back.
    var sent = false

    init(id: Int, text: String, recognized: String? = nil, audio: [Float], style: Options.TextStyle, engine: Engine?, sent: Bool) {
        self.id = id
        self.text = text
        self.recognized = recognized ?? text
        self.audio = audio
        self.style = style
        self.engine = engine
        self.sent = sent
    }

    enum Refusal: Equatable {
        case notOnScreen, sent, laterPaste, otherApp, edited, caretMismatch

        var message: String {
            switch self {
            case .notOnScreen: return "消せる貼り付けがありません"
            case .sent: return "送信済みなので消せません"
            case .laterPaste: return "後から別の貼り付けがあったので消せません"
            case .otherApp: return "別のアプリに移ったので消せません"
            case .edited: return "貼り付けの後に入力やクリックがあったので消せません"
            case .caretMismatch: return "カーソルの前が貼った文字と違うので消せません"
            }
        }
    }

    /// Why pressing Delete `text.count` times would not remove exactly this paste, or nil when it
    /// would: it is the latest paste, the app read it, and nothing was typed or clicked since in
    /// the same app. `caretFollows` is what the focused field reports (nil when it does not say).
    func refusalToDelete(latestPaste: Int, app currentApp: pid_t?, generation currentGeneration: Int, caretFollows: Bool?) -> Refusal? {
        guard let paste, !text.isEmpty else { return .notOnScreen }
        guard !sent else { return .sent }
        guard paste == latestPaste else { return .laterPaste }
        guard app != nil, currentApp == app else { return .otherApp }
        guard currentGeneration == generation else { return .edited }
        guard caretFollows != false else { return .caretMismatch }
        return nil
    }
}

/// The focused text field, read through Accessibility, as a last check before deleting.
enum FocusedText {
    /// Whether `text` is right before the caret with nothing selected; nil when the focused
    /// element does not expose its text and caret (many terminals and web views).
    static func caretFollows(_ text: String) -> Bool? {
        let system = AXUIElementCreateSystemWide()
        // An app that hangs must not hang the main thread with it.
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var rangeValue: CFTypeRef?
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return follows(text, value: string, selection: range)
    }

    /// `selection` is in UTF-16 units, as Accessibility reports it.
    static func follows(_ text: String, value: String, selection: CFRange) -> Bool? {
        let ns = value as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location + selection.length <= ns.length else { return nil }
        guard selection.length == 0 else { return false }
        return ns.substring(to: selection.location).hasSuffix(text)
    }
}

extension Engine {
    /// The model Fn+R re-recognizes with: Kotoba-Whisper (slower, more accurate, punctuated) for
    /// text from anything else, and back to ReazonSpeech for text from Kotoba-Whisper.
    static func alternative(to engine: Engine?, installed: (Engine) -> Bool = { $0.isInstalled }) -> Engine? {
        let order: [Engine] = engine == .kotoba ? [.reazon, .reazonJaEn] : [.kotoba, .reazon, .reazonJaEn]
        return order.first { $0 != engine && installed($0) }
    }
}

/// Recognition of a whole recording after the fact, the way dictation does it with any engine:
/// cut at pauses, each stretch recognized on its own, so 「、」 and spoken line breaks come out
/// the same.
enum Retranscriber {
    /// Throws if any stretch fails to decode: a result with a stretch missing must not replace
    /// the text.
    static func run(_ samples: [Float], detector: SpeechDetector?, style: Options.TextStyle,
                    recognize: ([Float]) throws -> String) throws -> String {
        let levels = PauseCutter.levels(samples)
        var after = 0
        var parts: [String] = []
        // As live: looked for every 100 ms on the audio so far.
        for end in stride(from: 5, through: levels.count, by: 5) {
            while let cut = PauseCutter.findCut(levels: Array(levels[..<end]), after: after) {
                let audio = Array(samples[after * PauseCutter.frameSize..<cut.frame * PauseCutter.frameSize])
                if detector?.containsSpeech(audio) ?? true {
                    parts.append(Intonation.markQuestion(try recognize(audio), audio: audio, enabled: style.questionMark))
                }
                after = cut.frame
            }
        }
        let rest = Array(samples.dropFirst(after * PauseCutter.frameSize))
        if !rest.isEmpty, after == 0 || (detector?.containsSpeech(rest) ?? true) {
            parts.append(Intonation.markQuestion(try recognize(rest), audio: rest, enabled: style.questionMark))
        }
        return PauseCutter.join(parts, style: style)
    }
}
