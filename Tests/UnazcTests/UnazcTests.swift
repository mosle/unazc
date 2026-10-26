import Foundation
import Testing
@testable import Unazc

@Suite struct JoinTests {
    @Test func pausesBecomeCommas() {
        #expect(PauseCutter.join(["今日は", "晴れ"], comma: true, newline: true) == "今日は、晴れ")
        #expect(PauseCutter.join(["今日は", "晴れ"], comma: false, newline: true) == "今日は晴れ")
    }

    @Test func noCommaAfterPunctuationOrEmptyParts() {
        #expect(PauseCutter.join(["本当？", "", "そう"], comma: true, newline: true) == "本当？そう")
    }

    @Test func spokenNewlineReplacesTheWordAndItsComma() {
        #expect(PauseCutter.join(["一行目", "改行。", "二行目"], comma: true, newline: true) == "一行目\n二行目")
        #expect(PauseCutter.join(["一", "次の段落", "二"], comma: true, newline: true) == "一\n\n二")
        #expect(PauseCutter.join(["一", "改行", "二"], comma: true, newline: false) == "一、改行、二")
    }
}

@Suite struct SnippetsTests {
    @Test func normalizeFoldsKanaWidthAndPunctuation() {
        #expect(Snippets.normalize("メールの、締め。") == Snippets.normalize("めーるの締め"))
        #expect(Snippets.normalize(" ＡＢＣ？\n") == "abc")
        #expect(Snippets.normalize("、。") == "")
        #expect(Snippets.normalize("署名™") == "署名")
        #expect(Snippets.normalize("署名 ✉️") == "署名")
        #expect(Snippets.normalize("ｶﾞｰﾙ") == "がーる")
    }

    @Test func parseReadsMultilineBodiesAndAliases() {
        let file = "# comment\nstray\n== メールの締め | しめ\n\nよろしく\n# kept\n山田\n\n==  、 \nlost\n== あ\r\nい\r\n== しめ\nignored\n"
        let (entries, skipped) = Snippets.parse(file)
        #expect(entries["めーるの締め"] == "よろしく\n# kept\n山田")
        #expect(entries["しめ"] == "よろしく\n# kept\n山田")
        #expect(entries["あ"] == "い")
        #expect(entries.count == 3)
        #expect(skipped == [2, 9, 10])
        #expect(Snippets.parse(Snippets.template).entries.isEmpty)
        #expect(Snippets.parse(Snippets.template).skipped.isEmpty)
    }

    @Test func matchOnlyTheWholeUtterance() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "== メールの締め\nよろしく\n山田\n".write(to: url, atomically: true, encoding: .utf8)
        let snippets = Snippets(url: url)
        #expect(snippets.match("メールの締め。") == "よろしく\n山田")
        #expect(snippets.match("では、メールの締め。") == nil)
        #expect(snippets.match("Mail", "めーるのしめ？") == nil)
        #expect(snippets.match("Mail", "めーるの締め？") == "よろしく\n山田")
        #expect(snippets.match("") == nil)
    }

    @Test func reloadsWhenTheFileChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "== a\none\n".write(to: url, atomically: true, encoding: .utf8)
        let snippets = Snippets(url: url)
        #expect(snippets.match("a") == "one")
        try "== a\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        #expect(snippets.match("a") == "two")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: url.path)
        #expect(snippets.match("a") == "two")
        try FileManager.default.removeItem(at: url)
        #expect(snippets.match("a") == nil)
    }

    @Test func triggersMatchAfterTheDictionaryOrAsRecognized() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "== Gitのしめ\nfixed\n== ぎっとのあいさつ\nraw\n".write(to: url, atomically: true, encoding: .utf8)
        let snippets = Snippets(url: url)
        let entries = Vocabulary.parse("ぎっと => Git").entries
        for (said, body) in [("ぎっとのしめ。", "fixed"), ("ぎっとのあいさつ", "raw")] {
            #expect(snippets.match(Vocabulary.apply(entries, to: said), said) == body)
        }
    }

    @Test func lastDictationRemembersWhatWasRecognized() {
        let style = Options.style(for: nil)
        #expect(LastDictation(id: 1, text: "a", audio: [], style: style, engine: nil, sent: false).recognized == "a")
        #expect(LastDictation(id: 1, text: "body", recognized: "said", audio: [], style: style, engine: nil, sent: false).recognized == "said")
    }
}

@Suite struct VocabularyTests {
    @Test func parseSkipsCommentsAndBadLines() {
        let (entries, skipped) = Vocabulary.parse("# comment\nぎっと => Git\nno arrow\n => empty\nぎっとはぶ => GitHub\n")
        #expect(entries.map(\.from) == ["ぎっとはぶ", "ぎっと"])
        #expect(skipped == [3, 4])
    }

    @Test func registeringAppendsOrReplacesTheSameSource() throws {
        let file = "# comment\nぎっと => Gitto\nほげ => fuga\n"
        #expect(try Vocabulary.registering(" ぎっと ", "Git", in: file) == "# comment\nぎっと => Git\nほげ => fuga\n")
        #expect(try Vocabulary.registering("ゆなず", "Unazc", in: file) == file + "ゆなず => Unazc\n")
        #expect(try Vocabulary.registering("ゆなず", "Unazc", in: "a => b") == "a => b\nゆなず => Unazc\n")
        #expect(throws: Vocabulary.RegisterError.emptySource) { try Vocabulary.registering(" ", "x", in: file) }
        #expect(throws: Vocabulary.RegisterError.newline) { try Vocabulary.registering("a", "b\nc", in: file) }
        #expect(throws: Vocabulary.RegisterError.arrowInSource) { try Vocabulary.registering("a=>b", "c", in: file) }
        #expect(throws: Vocabulary.RegisterError.commentSource) { try Vocabulary.registering(" #タグ", "c", in: file) }
        #expect(try Vocabulary.registering("ゆなず", "Unazc", in: "") == "ゆなず => Unazc\n")
        let added = try Vocabulary.registering("ゆなず", "Unazc", in: Vocabulary.template)
        #expect(Vocabulary.parse(added).entries.map(\.from) == ["ゆなず"])
    }

    @Test func registeringKeepsLineEndings() throws {
        let crlf = "# c\r\na => b\r\n\r\nc => d"
        #expect(try Vocabulary.registering("a", "x", in: crlf) == "# c\r\na => x\r\n\r\nc => d")
        #expect(try Vocabulary.registering("e", "f", in: crlf) == crlf + "\r\ne => f\r\n")
        #expect(try Vocabulary.registering("c", "y", in: "a => b\nc => d\r\n") == "a => b\nc => y\r\n")
        // Split like parse(): vertical tab and form feed end a line too.
        #expect(try Vocabulary.registering("a", "x", in: "a => b\u{0B}c => d") == "a => x\u{0B}c => d")
        #expect(try Vocabulary.registering("c", "y", in: "a => b\u{0C}c => d") == "a => b\u{0C}c => y")
    }

    @Test func registerWritesThroughASymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.txt"), link = dir.appendingPathComponent("vocab.txt")
        try "a => b\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try Vocabulary.register("ゆなず", "Unazc", url: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "a => b\nゆなず => Unazc\n")
        #expect(Vocabulary.existing("ゆなず", url: link) == "Unazc")
    }

    @Test func longestMatchWinsAndIsNotReplacedAgain() {
        let entries = [(from: "ぎっとはぶ", to: "GitHub"), (from: "ぎっと", to: "Git"), (from: "Git", to: "X")]
        #expect(Vocabulary.apply(entries, to: "ぎっとはぶとぎっと") == "GitHubとGit")
    }
}

@Suite struct IntonationTests {
    private func track(before: Double, end: Double) -> [Double?] {
        Array(repeating: before, count: 48) + Array(repeating: end, count: 12)
    }

    @Test func risingEndIsMeasuredInSemitones() throws {
        let rise = try #require(Intonation.endRise(track: track(before: 200, end: 260)))
        #expect(abs(rise - 4.54) < 0.01)
    }

    @Test func fallingEndIsNegative() throws {
        let rise = try #require(Intonation.endRise(track: track(before: 200, end: 180)))
        #expect(rise < 0)
    }

    @Test func tooLittleVoicingIsUnknown() {
        #expect(Intonation.endRise(track: [200, nil, nil, 210, nil]) == nil)
        #expect(Intonation.endRise(track: []) == nil)
    }
}

@Suite struct PreviewPolicyTests {
    @Test func fastMacPreviewsEvery300ms() {
        let p = PreviewPolicy(fixedMs: 15, msPerSecond: 20, cheap: true)
        #expect(p.everyTicks == 3)
        #expect(p.maxSamples == 68_000) // (100 - 15) / 20 = 4.25 s
    }

    @Test func slowerMacPreviewsLessOften() {
        let p = PreviewPolicy(fixedMs: 11, msPerSecond: 30, cheap: true)
        #expect(p.everyTicks == 4)
    }

    @Test func offWhenNotCheapOrTooSlow() {
        #expect(PreviewPolicy(fixedMs: 15, msPerSecond: 20, cheap: false).everyTicks == nil)
        #expect(PreviewPolicy(fixedMs: 400, msPerSecond: 0, cheap: true).everyTicks == nil)
        #expect(PreviewPolicy(fixedMs: 50, msPerSecond: 40, cheap: true).everyTicks == nil) // 1.25 s
    }
}

@Suite struct LastDictationTests {
    private func pasted(_ text: String = "こんにちは", sent: Bool = false) -> LastDictation {
        var last = LastDictation(id: 1, text: text, audio: [], style: Options.style(for: nil), engine: .reazon, sent: sent)
        last.paste = 3
        last.app = 42
        last.generation = 7
        return last
    }

    private func refusal(_ last: LastDictation, latestPaste: Int = 3, app: pid_t? = 42, generation: Int = 7,
                         caretFollows: Bool? = nil) -> LastDictation.Refusal? {
        last.refusalToDelete(latestPaste: latestPaste, app: app, generation: generation, caretFollows: caretFollows)
    }

    @Test func deletableRightAfterThePaste() {
        #expect(refusal(pasted()) == nil)
        #expect(refusal(pasted(), caretFollows: true) == nil)
    }

    @Test func refusedAfterInputAnotherAppOrSending() {
        #expect(refusal(pasted(), generation: 8) == .edited)
        #expect(refusal(pasted(), app: 43) == .otherApp)
        #expect(refusal(pasted(), app: nil) == .otherApp)
        #expect(refusal(pasted(sent: true)) == .sent)
    }

    @Test func refusedAfterALaterPasteOrWhenTheCaretDisagrees() {
        #expect(refusal(pasted(), latestPaste: 4) == .laterPaste)
        #expect(refusal(pasted(), caretFollows: false) == .caretMismatch)
    }

    @Test func refusedUntilReadAndOnceRemoved() {
        var last = pasted()
        last.paste = nil
        #expect(refusal(last) == .notOnScreen)
        #expect(refusal(pasted("")) == .notOnScreen)
        #expect(refusal(LastDictation(id: 1, text: "a", audio: [], style: Options.style(for: nil), engine: nil, sent: false)) == .notOnScreen)
    }

    @Test func caretCheckReadsTheTextBeforeAnEmptySelection() {
        let value = "前置き😀こんにちは後ろ"
        let caret = ("前置き😀こんにちは" as NSString).length // UTF-16, as Accessibility counts
        #expect(FocusedText.follows("こんにちは", value: value, selection: CFRange(location: caret, length: 0)) == true)
        #expect(FocusedText.follows("こんにちは", value: value, selection: CFRange(location: caret - 1, length: 0)) == false)
        #expect(FocusedText.follows("こんにちは", value: value, selection: CFRange(location: caret, length: 2)) == false)
        #expect(FocusedText.follows("こんにちは", value: value, selection: CFRange(location: 999, length: 0)) == nil)
    }

    @Test func alternativeModelTogglesBetweenWhisperAndReazon() {
        let all: (Engine) -> Bool = { _ in true }
        #expect(Engine.alternative(to: .reazon, installed: all) == .kotoba)
        #expect(Engine.alternative(to: .reazonJaEn, installed: all) == .kotoba)
        #expect(Engine.alternative(to: .kotoba, installed: all) == .reazon)
        #expect(Engine.alternative(to: nil, installed: all) == .kotoba)
        #expect(Engine.alternative(to: .reazon, installed: { $0 == .reazon }) == nil)
        #expect(Engine.alternative(to: .reazon, installed: { $0 != .kotoba }) == .reazonJaEn)
    }
}

/// Stands in for a model: returns canned text, or throws on the given call.
private final class FakeRecognizer: SpeechRecognizer {
    let name = "fake"
    let previewIsCheap: Bool
    private var outputs: [String]
    private let failOnCall: Int?
    private var calls = 0

    init(cheap: Bool, outputs: [String], failOnCall: Int? = nil) {
        previewIsCheap = cheap
        self.outputs = outputs
        self.failOnCall = failOnCall
    }

    func recognize(_ samples: [Float]) throws -> String {
        calls += 1
        if calls == failOnCall { throw RecognizerError.inferenceFailed(-1) }
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

@Suite struct RetranscriberTests {
    /// 1.5 s of tone, 0.6 s of silence, 1.5 s of tone: one pause.
    private let twoStretches: [Float] = {
        func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.2)) * 0.3 } }
        return tone(1.5) + [Float](repeating: 0, count: 9_600) + tone(1.5)
    }()

    @Test(arguments: [true, false])
    func everyEngineIsCutAtPausesLikeDictation(cheap: Bool) throws {
        let r = FakeRecognizer(cheap: cheap, outputs: ["一行目", "改行。"])
        let style = Options.TextStyle(pauseComma: true, questionMark: false, spokenNewline: true)
        let text = try Retranscriber.run(twoStretches, detector: nil, style: style, recognize: r.recognize)
        #expect(text == PauseCutter.join(["一行目", "改行。"], style: style))
        #expect(PauseCutter.join(["一行目", "改行。"], comma: true, newline: true) == "一行目\n")
    }

    @Test func aFailedStretchFailsTheWhole() {
        let r = FakeRecognizer(cheap: true, outputs: ["前半", "後半"], failOnCall: 2)
        #expect(throws: (any Error).self) { try Retranscriber.run(twoStretches, detector: nil, style: Options.style(for: nil), recognize: r.recognize) }
    }
}

@Suite struct BackchannelTests {
    private func choose(_ text: String, seconds: Double = 1.5, sinceLast: Double = 10, roll: Double = 0) -> Backchannel.Kind? {
        Backchannel.choose(text: text, stretchSeconds: seconds, sinceLast: sinceLast, roll: roll)
    }

    @Test func questionMostlyGetsAgreement() {
        #expect(choose("明日来る？", roll: 0.499) == .ack)
        #expect(choose("明日来る？", roll: 0.5) == .q)
        #expect(choose("明日来る？", roll: 0.799) == .q)
        #expect(choose("明日来る？", roll: 0.8) == nil)
    }

    @Test func longStretchGetsADoubleNod() {
        #expect(choose("今日は朝から会議が続いていて", seconds: 1.5) == .ack)
        #expect(choose("今日は朝から会議が続いていて", seconds: 4) == .cont) // a long stretch wins
        #expect(choose("今日は朝から会議が続いていた", seconds: 4) == .cont)
    }

    @Test func notOnlyUn() {
        #expect(choose("そうです", roll: 0.5) == .cont)
        #expect(choose("言ってたけど", roll: 0.6) == .cont)
    }

    @Test func boundaries() {
        // Plain ending: ack below 0.35, cont below 0.6, else quiet.
        #expect(choose("そうです", roll: 0.349) == .ack)
        #expect(choose("そうです", roll: 0.35) == .cont)
        #expect(choose("そうです", roll: 0.599) == .cont)
        #expect(choose("そうです", roll: 0.6) == nil)
        // Open ending: ack below 0.5, cont below 0.8.
        #expect(choose("言ってたけど", roll: 0.499) == .ack)
        #expect(choose("言ってたけど", roll: 0.5) == .cont)
        #expect(choose("言ってたけど", roll: 0.799) == .cont)
        #expect(choose("言ってたけど", roll: 0.8) == nil)
        // From 3 s on, cont below 0.8, even after an open ending.
        #expect(choose("そうです", seconds: 2.999, roll: 0.1) == .ack)
        #expect(choose("そうです", seconds: 3, roll: 0.1) == .cont)
        #expect(choose("言ってたけど", seconds: 3, roll: 0.1) == .cont)
        #expect(choose("言ってたけど", seconds: 3, roll: 0.8) == nil)
        #expect(choose("そうです", sinceLast: 1.499) == nil)
        #expect(choose("そうです", sinceLast: 1.5) == .ack)
    }

    @Test func quietForNoiseRightAfterAReplyOrSometimes() {
        #expect(choose("") == nil)
        #expect(choose("そうです", sinceLast: 0.5) == nil)
        #expect(choose("そうです", roll: 0.9) == nil)
        #expect(choose("そうです", roll: 0.1) == .ack)
    }
}

@Suite struct BackchannelSoundsTests {
    @Test func picksFilesByPrefixAndIgnoresTheRestAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unazc-bc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["q-1.wav", "ack-2.wav", "ack-1.wav", "cont-1.m4a", "README.md", "acknowledge.wav"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ack-backup"), withIntermediateDirectories: false)
        let found = Backchannel.sounds(in: dir).map { "\($0.0.rawValue):\($0.1.lastPathComponent)" }
        #expect(found == ["ack:ack-1.wav", "ack:ack-2.wav", "cont:cont-1.m4a", "q:q-1.wav"])
    }

    @Test func bundledSetCoversEveryKind() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/backchannel").standardized
        let kinds = Set(Backchannel.sounds(in: dir).map(\.0))
        #expect(kinds == Set(Backchannel.Kind.allCases))
    }
}

@Suite struct TrailingPauseTests {
    // 0.2 = speech, 0.001 = silence; the threshold needs 50 frames to judge.
    private func levels(_ pattern: [(Float, Int)]) -> [Float] { pattern.flatMap { Array(repeating: $0.0, count: $0.1) } }

    @Test func noneWhileSpeaking() {
        #expect(PauseCutter.trailingPause(levels: levels([(0.2, 60)]), after: 0) == nil)
        #expect(PauseCutter.trailingPause(levels: levels([(0.2, 30)]), after: 0) == nil)
    }

    @Test func measuresTheCurrentPause() throws {
        let pause = try #require(PauseCutter.trailingPause(levels: levels([(0.2, 40), (0.001, 5), (0.2, 20), (0.001, 12)]), after: 0))
        #expect(pause.start == 65)
        #expect(pause.silentFrames == 12)
        #expect(pause.voicedFrames == 60)
    }

    @Test func countsSpeechOnlyAfterTheGivenFrame() throws {
        let pause = try #require(PauseCutter.trailingPause(levels: levels([(0.2, 40), (0.001, 5), (0.2, 20), (0.001, 12)]), after: 45))
        #expect(pause.start == 65)
        #expect(pause.voicedFrames == 20)
        // A pause that began before `after` is measured from `after`.
        let late = try #require(PauseCutter.trailingPause(levels: levels([(0.2, 60), (0.001, 12)]), after: 66))
        #expect(late.start == 66)
        #expect(late.voicedFrames == 0)
    }
}

@Suite struct RecordKeyModeTests {
    @Test func onlyToggleAndShortTapsInBothLatch() {
        #expect(!Options.RecordKeyMode.hold.latches(heldMs: 100))
        #expect(Options.RecordKeyMode.toggle.latches(heldMs: 2000))
        #expect(Options.RecordKeyMode.both.latches(heldMs: Options.RecordKeyMode.tapMs - 1))
        #expect(!Options.RecordKeyMode.both.latches(heldMs: Options.RecordKeyMode.tapMs))
    }
}

@Suite(.serialized) struct AppOverrideTests {
    private let app = "test.unazc.override"

    @Test func anOverrideBeatsTheGlobalSettingAndRemovingItFollowsAgain() {
        defer { Options.removeOverrides(app: app) }
        let global = Options.TextOption.pauseComma.global
        Options.setOverride(.pauseComma, app: app, !global)
        #expect(Options.style(for: app).pauseComma == !global)
        #expect(Options.style(for: "test.unazc.other").pauseComma == global)
        #expect(Options.style(for: app).spokenNewline == Options.TextOption.spokenNewline.global)
        Options.setOverride(.pauseComma, app: app, nil)
        #expect(Options.style(for: app).pauseComma == global)
        #expect(!Options.appsWithOverrides.contains(app))
    }
    @Test func everyOptionCanBeSetOnOrOff() {
        defer { Options.removeOverrides(app: app) }
        for option in Options.TextOption.allCases {
            for value in [true, false] {
                Options.setOverride(option, app: app, value)
                #expect(Options.value(option, app: app) == value)
            }
        }
    }

    /// A dictation keeps the style it started with, and Fn+R re-recognizes with it too.
    @Test func aStyleTakenAtTheStartIsKeptThroughAChange() throws {
        defer { Options.removeOverrides(app: app) }
        Options.setOverride(.pauseComma, app: app, false)
        let style = Options.style(for: app)
        Options.setOverride(.pauseComma, app: app, true)
        #expect(!style.pauseComma)
        let tone = (0..<24_000).map { Float(sin(Double($0) * 0.2)) * 0.3 }
        let audio = tone + [Float](repeating: 0, count: 9_600) + tone
        let r = FakeRecognizer(cheap: true, outputs: ["今日は", "晴れ"])
        #expect(try Retranscriber.run(audio, detector: nil, style: style, recognize: r.recognize) == "今日は晴れ")
    }
}

@Suite struct MicCheckTests {
    @Test func workingMicPasses() {
        #expect(MicCheck.problem(frames: 60, peak: 0.002, elapsedMs: 1_200, device: "Mic") == nil)
    }

    @Test func slowDeviceStillPasses() {
        // Opened 0.4 s late: two thirds of the frames.
        #expect(MicCheck.problem(frames: 40, peak: 0.002, elapsedMs: 1_200, device: nil) == nil)
    }

    @Test func noAudioArriving() {
        #expect(MicCheck.problem(frames: 0, peak: 0, elapsedMs: 1_200, device: "USB")
            == "マイク（USB）から音が届いていません")
    }

    @Test func digitalSilence() {
        #expect(MicCheck.problem(frames: 60, peak: 0, elapsedMs: 1_200, device: nil)
            == "マイクの音が無音です。ミュートやマイクの許可を確認してください")
    }
}
