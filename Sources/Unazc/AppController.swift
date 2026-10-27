import AppKit
import os
import AVFoundation

enum Paths {
    static var vadModel: URL {
        if let env = ProcessInfo.processInfo.environment["UNAZC_VAD_MODEL"] { return URL(fileURLWithPath: env) }
        return Engine.modelsRoot.appendingPathComponent("silero_vad.onnx")
    }
}

/// Recognized text of one push-to-talk, built up segment by segment. Everything but `cancelled`
/// is confined to the ASR queue; `cancelled` is set from the record queue and takes effect at once,
/// so segments still waiting in the queue are skipped instead of delaying the next utterance.
private final class Utterance {
    /// The text options of the app in front when it started.
    let style: Options.TextStyle
    var parts: [String] = []
    var segments = 0
    var segmentAudio = 0.0
    private let lock = NSLock()
    init(style: Options.TextStyle) { self.style = style }
    private var _cancelled = false
    private var _finished = false
    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }
    /// Set at release (cleared if pressed again within the post-roll); no preview starts after it,
    /// so the final recognition is never queued behind a new one.
    var finished: Bool {
        get { lock.withLock { _finished } }
        set { lock.withLock { _finished = newValue } }
    }
}

/// Opt-in (`defaults write io.github.mosle.unazc debugSaveAudio -bool true`): saves every recording
/// as a WAV so misrecognitions can be replayed.
enum DebugAudio {
    private static let queue = DispatchQueue(label: "unazc.debugaudio", qos: .utility)
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Unazc/debug")

    /// Millisecond timestamps sort in recording order; the suffix keeps names unique.
    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        return f
    }()

    static func save(_ samples: [Float]) {
        guard UserDefaults.standard.bool(forKey: "debugSaveAudio"), !samples.isEmpty else { return }
        let name = Self.nameFormatter.string(from: Date()) + "-" + UUID().uuidString.prefix(4) + ".wav"
        queue.async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: AudioRecorder.targetFormat.settings)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioRecorder.targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try file.write(from: buffer)
                let old = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(20)
                for url in old { try? fm.removeItem(at: url) }
            } catch {
                Log.info("debug audio save failed: \(error)")
            }
        }
    }
}

final class AppController: NSObject {
    /// Shorter presses are treated as accidental taps.
    private let minHoldSeconds = 0.25

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "起動中…", action: nil, keyEquivalent: "")
    private let engineMenu = NSMenu()
    private let optionsMenu = NSMenu()
    /// Used on asrQueue only.
    private let vocabulary = Vocabulary()
    private let snippets = Snippets()
    /// Main thread. The engine in use and the one being loaded; only one load runs at a time.
    private var activeEngine: Engine?
    private var loadingEngine: Engine?
    private let recorder = AudioRecorder()
    private let inserter = PasteInserter()
    private var hotkey: HotkeyMonitor?
    /// Recording start/stop runs here, so a busy main thread cannot shift what gets recorded.
    /// `recorder`, `pressedAt` and `ready` are confined to this queue.
    private let recordQueue = DispatchQueue(label: "unazc.record", qos: .userInteractive)
    private var pressedAt: Double = 0
    private var ready = false
    /// The pending stop during post-roll; also confined to `recordQueue`.
    private var pendingFinish: DispatchWorkItem?
    /// Confined to `recordQueue`: judges whether speech had ended at release, so the post-roll can
    /// be skipped. nil if the VAD model is missing; then a loudness check is used instead.
    private var tailDetector: SpeechDetector?
    /// Confined to `recordQueue`: closes the idle microphone when its keep-open time runs out.
    private var micCloseItem: DispatchWorkItem?
    /// Confined to `recordQueue`: when the stream was last reopened after a device change, so a
    /// reopen that itself triggers a change notification cannot loop.
    private var lastMicReopen: Double = -.infinity
    /// Confined to `recordQueue`: counts recordings, so a delayed diagnostic knows its own.
    private var recordingID = 0
    /// Main thread only.
    private let overlay = LiveOverlay()
    private let backchannel = Backchannel()
    private let mediaPauser = MediaPauser()
    private let frontApp = FrontApp()
    private let vocabularyWindow = VocabularyWindow()
    private lazy var callWindow: CallWindow = {
        let window = CallWindow()
        window.onHangUp = { [weak self] in
            Options.callWindow = false
            self?.callOptionsChanged()
        }
        window.onOpenSettings = { [weak self] in self?.settings.show() }
        window.onSetOnTop = { [weak self] on in
            Options.callOnTop = on
            self?.callOptionsChanged()
        }
        window.onSetOpacity = { [weak self] value in
            Options.callOpacity = value
            self?.callOptionsChanged()
        }
        window.onSetCompact = { [weak self] on in
            Options.callCompact = on
            self?.callOptionsChanged()
        }
        return window
    }()
    private lazy var settings = SettingsWindow(actions: .init(
        engines: { [unowned self] in (activeEngine, loadingEngine) },
        selectEngine: { [unowned self] engine in
            guard engine != activeEngine else { return }
            loadRecognizer(engine)
        },
        optionsChanged: { [unowned self] in callOptionsChanged() },
        micPolicyChanged: { [unowned self] in recordQueue.async { self.applyMicPolicy() } },
        isLoginEnabled: { LoginAgent.isEnabled },
        setLogin: { [unowned self] on in
            LoginAgent.setEnabled(on)
            updateLoginItem()
        },
        editVocabulary: { [unowned self] in editVocabulary() },
        editSnippets: { [unowned self] in editSnippets() },
        openLog: { [unowned self] in openLog() }))
    /// When unazc last replied (a nod, a sound, or both), in `nowMs`. Main thread only.
    private var lastReplyAt = -Double.infinity
    /// Main thread: how the live panel behaves on this Mac, shown in the options menu.
    private var previewSummary = ""
    /// Main thread: the front app's text options, rebuilt each time the menu opens (a menu-bar menu
    /// does not take the front from it).
    private let appOptionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Main thread: the status line shows `idleHintText`.
    private var showingIdleHint = false
    private lazy var registerItem = NSMenuItem(title: "", action: #selector(registerWord), keyEquivalent: "").withTarget(self)
    private lazy var loginItem = NSMenuItem(title: "ログイン時に起動・落ちたら自動で再起動", action: #selector(toggleLogin), keyEquivalent: "").withTarget(self)
    /// Confined to `recordQueue`: segment-timer ticks, to run a preview every few of them.
    private var previewTick = 0
    /// Set on `asrQueue` after a model loads, read on `recordQueue`.
    private let previewPolicy = OSAllocatedUnfairLock(initialState: PreviewPolicy.off)
    /// The current recording's text and the frame up to which it has been sent for recognition
    /// (both `recordQueue`). Segments are recognized at pauses while still recording, so on release
    /// only the audio after the last pause is left to do.
    private var utterance: Utterance?
    private var segmentedFrames = 0
    /// `recordQueue`: the end of the last pause judged for a reply, whether or not one was given
    /// (see replyIfPausing); speech is counted from here.
    private var replyFrom = 0
    /// The latest preview text, with the recording and the frame its audio started at; written on
    /// `asrQueue`, read on `recordQueue`.
    private let openPartial = OSAllocatedUnfairLock(initialState: (recording: -1, from: -1, text: ""))
    private var segmentTimer: DispatchSourceTimer?
    /// Confined to `asrQueue`, with the engine it was made from.
    private var recognizer: SpeechRecognizer?
    private var recognizerEngine: Engine?
    private let asrQueue = DispatchQueue(label: "unazc.asr", qos: .userInteractive)
    /// Confined to `asrQueue`. nil if the VAD model is missing; then every segment is recognized.
    private var detector: SpeechDetector?
    /// Main-thread copy of "model loaded", for the status line only.
    private var modelLoaded = false
    /// Main thread: what Fn+V / Fn+Z / Fn+R act on, and a count of dictations for its id.
    private var last: LastDictation?
    private var dictationCount = 0
    /// Main thread: pastes sent, of any kind.
    private var pasteCount = 0
    /// Main thread: an Fn+R recognition is running.
    private var retrying = false
    /// Re-recognition runs here, not on `asrQueue`, so dictation never waits behind it. The other
    /// model is kept loaded for a while after use, then freed. Both confined to `retryQueue`.
    private let retryQueue = DispatchQueue(label: "unazc.retry", qos: .userInitiated)
    private var retryRecognizer: (engine: Engine, recognizer: SpeechRecognizer, lastUse: Double)?
    private var retryDetector: SpeechDetector?
    private let retryKeepSeconds = 300.0

    func start() {
        Log.info("started \(LoginAgent.isAgentProcess ? "by launchd" : "by hand"), agent \(LoginAgent.isEnabled ? "on" : "off")")
        setUpStatusItem()
        setUpMainMenu()
        applyCallWindow()
        // Quitting or SIGTERM mid-dictation must not leave the music paused. SIGTERM is caught only
        // when launchd runs the app; a copy opened by hand still dies with the music paused.
        let pauser = mediaPauser
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            pauser.restoreBeforeExit()
        }
        LoginAgent.beforeExit = { pauser.restoreBeforeExit() }
        requestPermissions()
        loadRecognizer(Engine.selected)
        recorder.onConfigurationChange = { [weak self] in
            guard let self else { return }
            recordQueue.async { self.micConfigurationChanged() }
        }
        recordQueue.async { [self] in
            do {
                tailDetector = try SpeechDetector(model: Paths.vadModel, minSilence: SpeechDetector.tailMinSilence)
            } catch {
                Log.info("tail VAD unavailable, judging end of speech by loudness: \(error)")
            }
        }

        startHotkey()
    }

    /// Retries every second so granting Accessibility takes effect without a relaunch.
    private func startHotkey() {
        let hotkey = HotkeyMonitor(queue: recordQueue) { [weak self] event in self?.handle(event) }
        if hotkey.start() {
            self.hotkey = hotkey
            Log.info("event tap started")
            if modelLoaded { setStatus(idleHintText, idleHint: true) }
        } else {
            setStatus("アクセシビリティ権限を許可してください")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startHotkey() }
        }
    }

    // MARK: - Push to talk

    /// Runs on `recordQueue`.
    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .press(let time, let reject):
            // Pressed again within the post-roll: keep the same recording going as one utterance.
            if let pending = pendingFinish {
                pending.cancel()
                pendingFinish = nil
                utterance?.finished = false
                setRecording(true)
                Log.info("resumed within post-roll")
                return
            }
            guard ready, !recorder.isRunning else { return reject() }
            pressedAt = time
            micCloseItem?.cancel()
            micCloseItem = nil
            do {
                try recorder.start()
                startSegmenting()
                warmUpIfIdle()
                setRecording(true)
                Log.info("record start (\(Int(nowMs() - pressedAt))ms after press)")
                recordingID += 1
                logCaptureStart(pressedAt: pressedAt, id: recordingID)
                let id = recordingID, startedAt = nowMs()
                recordQueue.asyncAfter(deadline: .now() + MicCheck.afterSeconds) { [self] in
                    checkMic(id: id, startedAt: startedAt)
                }
                if Options.liveText {
                    DispatchQueue.main.async { [self] in overlay.show(session: id) }
                }
            } catch {
                Log.info("record start failed: \(error)")
                reject()
            }
        case .command(let command):
            DispatchQueue.main.async { [self] in run(command) }
        case .cancel:
            guard recorder.isRunning, pendingFinish == nil else { return }
            discardUtterance()
            _ = recorder.takeSamples()
            releaseMic()
            setRecording(false)
            Log.info("cancelled")
        case .release(let tRelease, let send):
            guard recorder.isRunning, pendingFinish == nil else { return }
            let held = (tRelease - pressedAt) / 1000
            guard held >= minHoldSeconds else {
                discardUtterance()
                _ = recorder.takeSamples()
                releaseMic()
                setRecording(false)
                Log.info("ignored short press \(String(format: "%.2f", held))s")
                return
            }
            // From the release on, no new preview may start: one would hold up the final pass.
            utterance?.finished = true
            awaitTail(tRelease: tRelease, tHandled: nowMs(), send: send)
        }
    }

    /// Runs on `recordQueue`. Waits (in short steps, cancellable by a re-press through
    /// `pendingFinish`) until audio up to the release has arrived. If the tail is already silent the
    /// user had finished talking, so recognition starts at once; otherwise the post-roll runs out.
    private func awaitTail(tRelease: Double, tHandled: Double, send: Bool) {
        let postRollMs = Options.postRollMs
        let elapsed = nowMs() - tRelease
        if elapsed >= postRollMs {
            pendingFinish = nil
            return finishRecording(tRelease: tRelease, tHandled: tHandled, send: send)
        }
        var delay = postRollMs - elapsed
        if recorder.hasCaptured(through: tRelease) {
            if Options.skipPostRollWhenDone, speechEnded() {
                pendingFinish = nil
                return finishRecording(tRelease: tRelease, tHandled: tHandled, send: send)
            }
        } else {
            delay = min(delay, 5)
        }
        let next = DispatchWorkItem { [self] in awaitTail(tRelease: tRelease, tHandled: tHandled, send: send) }
        pendingFinish = next
        recordQueue.asyncAfter(deadline: .now() + delay / 1000, execute: next)
    }

    // MARK: - Microphone open/close

    /// Runs on `recordQueue` after a recording ends.
    private func releaseMic() {
        micCloseItem?.cancel()
        micCloseItem = nil
        let seconds = Options.micKeepOpenSeconds
        // The device changed during the recording: the stream is dead, so do not keep it.
        if recorder.isStreaming, recorder.needsRebuild {
            recorder.shutdown()
            if seconds < 0 { reopenMicSoon() }
            return
        }
        if seconds == 0 {
            recorder.shutdown()
        } else if seconds > 0 {
            let item = DispatchWorkItem { [self] in
                micCloseItem = nil
                guard !recorder.isRunning, pendingFinish == nil else { return }
                recorder.shutdown()
                Log.info("microphone closed after \(Int(seconds))s idle")
            }
            micCloseItem = item
            recordQueue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    /// Runs on `recordQueue`: applies the keep-open option when it changes or at launch. "Always"
    /// opens the input right away; otherwise an idle stream gets the new close timing.
    private func applyMicPolicy() {
        guard !recorder.isRunning, pendingFinish == nil else { return }
        if Options.micKeepOpenSeconds < 0 {
            micCloseItem?.cancel()
            micCloseItem = nil
            openIdleMic()
        } else if recorder.isStreaming {
            releaseMic()
        }
    }

    private func openIdleMic() {
        do {
            try recorder.openStream()
        } catch {
            Log.info("could not keep the microphone open: \(error)")
        }
    }

    /// Runs on `recordQueue`. A device change kills an open idle stream: close it, and reopen it
    /// when the option says always (at most once per 5 s, in case reopening reports a change too).
    /// A recording in progress is left alone; `releaseMic()` closes the stream when it ends.
    private func micConfigurationChanged() {
        guard !recorder.isRunning, pendingFinish == nil, recorder.isStreaming else { return }
        recorder.shutdown()
        if Options.micKeepOpenSeconds < 0 { reopenMicSoon() }
    }

    private func reopenMicSoon() {
        guard nowMs() - lastMicReopen > 5_000 else {
            Log.info("microphone changed again right after reopening; it opens on the next press")
            return
        }
        lastMicReopen = nowMs()
        recordQueue.asyncAfter(deadline: .now() + 1) { [self] in
            guard !recorder.isRunning, !recorder.isStreaming, Options.micKeepOpenSeconds < 0 else { return }
            openIdleMic()
        }
    }

    /// Logs how much audio after the press was lost before capture began (head) and the tap buffer
    /// size, once the first buffer is in.
    private func logCaptureStart(pressedAt: Double, id: Int, attempt: Int = 0) {
        guard id == recordingID, recorder.isRunning else { return }
        let info = recorder.captureInfo()
        guard let first = info.firstCapture else {
            if attempt < 40 {
                recordQueue.asyncAfter(deadline: .now() + 0.025) { [self] in
                    logCaptureStart(pressedAt: pressedAt, id: id, attempt: attempt + 1)
                }
            }
            return
        }
        Log.info(String(format: "capture head=%.0fms buffer=%d@%.0fHz (%.0fms) delivered %.0fms late",
                        first - pressedAt, info.frames, info.rate, Double(info.frames) / info.rate * 1000, info.delayMs))
    }

    /// Runs on `recordQueue` a moment into recording `id`: warns if the microphone gives nothing.
    private func checkMic(id: Int, startedAt: Double) {
        guard id == recordingID, recorder.isRunning, let level = recorder.inputLevel() else { return }
        let elapsed = nowMs() - startedAt
        guard let message = MicCheck.problem(frames: level.frames, peak: level.peak, elapsedMs: elapsed,
                                             device: MicCheck.inputDeviceName()) else { return }
        Log.info(String(format: "mic check: %@ (frames=%d peak=%.2e after %.0fms)", message, level.frames, level.peak, elapsed))
        DispatchQueue.main.async { [self] in
            setStatus(message)
            if !overlay.warn(session: id, message) { overlay.flash(message, seconds: 3) }
        }
    }

    /// Runs on `recordQueue`, once audio up to the release has arrived.
    private func speechEnded() -> Bool {
        guard let tailDetector else { return recorder.tailIsSilent(tailMs: 200, ratio: 0.15, absolute: 0.01) }
        let t = nowMs()
        // Too little audio to judge (e.g. a cold start that just began): keep the post-roll.
        let audio = recorder.recentSamples(ms: 800)
        guard audio.count >= 800 * 16 else { return false }
        // The VAD confirms speech only ~0.1 s after it starts, so "not speaking" alone could cut a
        // word begun right before the release; the tail must also be down at the noise floor.
        let vadQuiet = !tailDetector.isSpeaking(atEndOf: audio)
        let floorQuiet = recorder.tailNearNoiseFloor(tailMs: 150)
        let ended = vadQuiet && floorQuiet
        Log.info(String(format: "tail ended=%@ vad=%@ floor=%@ (%.1fms)", ended ? "yes" : "no",
                        vadQuiet ? "quiet" : "speech", floorQuiet ? "quiet" : "loud", nowMs() - t))
        return ended
    }

    // MARK: - Segments

    /// Recognition jobs queued or running on `asrQueue`.
    private let pendingASR = OSAllocatedUnfairLock(initialState: 0)

    private func enqueueASR(_ job: @escaping () -> Void) {
        pendingASR.withLock { $0 += 1 }
        asrQueue.async { [self] in
            job()
            pendingASR.withLock { $0 -= 1 }
        }
    }

    /// Runs on `recordQueue` at press. Wakes the CPU from idle with a dummy decode while the user
    /// talks, so the real one runs at full speed. Skipped when recognition is already busy (the CPU
    /// is awake anyway) or the utterance is gone by the time it would run.
    private func warmUpIfIdle() {
        guard let utterance, pendingASR.withLock({ $0 == 0 }) else { return }
        enqueueASR { [self] in
            guard !utterance.cancelled else { return }
            _ = recognizer?.transcribe([Float](repeating: 0, count: 4_800))
        }
    }

    /// Runs on `recordQueue`.
    private func startSegmenting() {
        utterance = Utterance(style: Options.style(for: frontApp.bundleID))
        segmentedFrames = 0
        replyFrom = 0
        let timer = DispatchSource.makeTimerSource(queue: recordQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.recognizeFinishedSegments() }
        timer.resume()
        segmentTimer = timer
    }

    /// Runs on `recordQueue`: sends every stretch that ended in a pause to the ASR queue.
    private func recognizeFinishedSegments() {
        guard recorder.isRunning, let utterance else { return }
        let id = recordingID
        // Before cutting: the preview it uses belongs to the stretch as it was before the cut.
        replyIfPausing(utterance, id: id)
        while let (cut, audio) = recorder.takeSegment(after: segmentedFrames) {
            segmentedFrames = cut.frame
            enqueueASR { [self] in
                // A segment of pure room noise would come back as an invented syllable.
                guard !utterance.cancelled, detector?.containsSpeech(audio) ?? true else { return }
                let text = Intonation.markQuestion(recognizer?.transcribe(audio) ?? "", audio: audio,
                                                   enabled: utterance.style.questionMark)
                utterance.parts.append(text)
                utterance.segments += 1
                utterance.segmentAudio += Double(audio.count) / 16_000
                if Options.liveText, !utterance.finished {
                    let committed = vocabulary.apply(to: PauseCutter.join(utterance.parts, style: utterance.style))
                    DispatchQueue.main.async { [self] in overlay.update(session: id, committed: committed, full: committed) }
                }
            }
        }
        previewTick += 1
        let policy = previewPolicy.withLock { $0 }
        if let every = policy.everyTicks, previewTick % every == 0 {
            previewOpenSegment(utterance, id: id, maxSamples: policy.maxSamples)
        }
    }

    /// Runs on `recordQueue` every tick: after `replyAfterMs` of quiet, replies from the latest preview
    /// and intonation instead of waiting for the pause to be cut and recognized; a person's 「うん」
    /// comes about that soon. Each pause is judged once.
    private func replyIfPausing(_ utterance: Utterance, id: Int) {
        guard Options.backchannel || Options.callWindow,
              let pause = recorder.trailingPause(after: replyFrom),
              pause.silentFrames * 20 >= Self.replyAfterMs, pause.voicedFrames * 20 >= 600, pause.start > replyFrom else { return }
        // How long they talked since the last judged pause: a long stretch gets 「なるほど」 rather than 「うん」.
        let seconds = Double(pause.start - replyFrom) * 0.02
        replyFrom = pause.start + pause.silentFrames
        let partial = openPartial.withLock { $0 }
        let said: String
        if partial.recording == id, partial.from == segmentedFrames {
            // The voice detector heard no speech in this stretch: nothing to reply to.
            guard !partial.text.isEmpty else { return }
            said = partial.text
        } else {
            // No preview yet, or none at all (engines where it is not cheap): the levels say there
            // was speech, so reply from its length and intonation alone.
            said = "…"
        }
        let spoken = recorder.audio(fromFrame: max(pause.start - 150, 0))
        let text = Intonation.soundsLikeQuestion(said, audio: spoken) ? said + "？" : said
        let deadline = nowMs() + 250
        DispatchQueue.main.async { [self] in
            reply(to: text, seconds: seconds, deadline: deadline) { !utterance.cancelled && !utterance.finished }
        }
    }

    /// Quiet this long (ms) counts as a pause to reply to; a pause is cut for recognition at 400.
    private static let replyAfterMs = 240

    /// Runs on `recordQueue` about every 0.3 s: recognizes the stretch still being spoken, for the
    /// overlay and for replies. Skipped while any recognition is queued, so previews never pile up, and for
    /// engines where it is not cheap; at most one (~50-100 ms) can be running at the release.
    private func previewOpenSegment(_ utterance: Utterance, id: Int, maxSamples: Int) {
        guard Options.liveText || Options.backchannel || Options.callWindow, !utterance.finished,
              pendingASR.withLock({ $0 == 0 }) else { return }
        let from = segmentedFrames
        let audio = recorder.audio(fromFrame: from)
        // Under 0.3 s there is nothing to read yet; past the policy's length a preview would cost
        // too much if the key is released while it runs.
        guard audio.count >= 4_800, audio.count <= maxSamples else { return }
        enqueueASR { [self] in
            // The model may have been switched since this was queued; obey the current policy.
            let current = previewPolicy.withLock { $0 }
            guard !utterance.cancelled, !utterance.finished, recognizer?.previewIsCheap == true,
                  current.everyTicks != nil, audio.count <= current.maxSamples else { return }
            let partial = detector?.containsSpeech(audio) ?? true ? recognizer?.transcribe(audio) ?? "" : ""
            // Tagged with the recording, so a late result is never read as part of the next one.
            openPartial.withLock { $0 = (id, from, partial) }
            guard Options.liveText, !utterance.finished else { return }
            let committed = vocabulary.apply(to: PauseCutter.join(utterance.parts, style: utterance.style))
            let full = vocabulary.apply(to: PauseCutter.join(utterance.parts + [partial], style: utterance.style))
            DispatchQueue.main.async { [self] in overlay.update(session: id, committed: committed, full: full) }
        }
    }

    /// Main thread: unazc's reply to a stretch that just ended, a nod on the call screen and a sound in
    /// headphones, or nothing (see Backchannel.choose). Dropped once `deadline` passes.
    private func reply(to text: String, seconds: Double, deadline: Double, stillWanted: @escaping () -> Bool) {
        guard stillWanted(), nowMs() < deadline,
              let kind = Backchannel.choose(text: text, stretchSeconds: seconds, sinceLast: (nowMs() - lastReplyAt) / 1000,
                                            roll: Double.random(in: 0..<1)) else { return }
        var replied = false
        if Options.backchannel, backchannel.play(kind, deadline: deadline, stillWanted: { Options.backchannel && stillWanted() }) {
            replied = true
        }
        // After the sound, which may first load files: checked again so a late nod is dropped too.
        if Options.callWindow, stillWanted(), nowMs() < deadline {
            callWindow.nod()
            replied = true
        }
        // Taken after the sound starts, so the gap is measured from what the user actually heard.
        if replied {
            lastReplyAt = nowMs()
            Log.info("reply \(kind.rawValue) to …\(text.suffix(8)) (\(String(format: "%.1f", seconds))s)")
        }
    }

    /// After an option changed outside the menu.
    private func callOptionsChanged() {
        updateOptionsMenu()
        applyCallWindow()
    }

    private func applyCallWindow() {
        callWindow.apply(visible: Options.callWindow, onTop: Options.callOnTop, opacity: Options.callOpacity,
                         compact: Options.callCompact, recordKey: Options.recordKeyTitle)
    }

    /// Runs on `recordQueue`. Returns the utterance so far and stops looking for pauses.
    private func stopSegmenting() -> (Utterance, Int)? {
        segmentTimer?.cancel()
        segmentTimer = nil
        defer { utterance = nil }
        return utterance.map { ($0, segmentedFrames) }
    }

    /// Runs on `recordQueue`: segments already queued for recognition are thrown away.
    private func discardUtterance() {
        guard let (utterance, _) = stopSegmenting() else { return }
        utterance.cancelled = true
    }

    /// Runs on `recordQueue` once the tail is known to be silent or the post-roll has elapsed.
    private func finishRecording(tRelease: Double, tHandled: Double, send: Bool) {
        let session = stopSegmenting()
        session?.0.finished = true
        let samples = recorder.takeSamples()
        let utterance = session?.0 ?? Utterance(style: Options.style(for: frontApp.bundleID))
        let segmented = session?.1 ?? 0
        let rest = Array(samples.dropFirst(segmented * PauseCutter.frameSize))
        let tStopped = nowMs()
        DebugAudio.save(samples)
        defer {
            // After queuing recognition, so stopping the engine is off the critical path.
            releaseMic()
            setRecording(false)
        }
        // The ASR queue is serial, so every earlier segment of this utterance is done by now.
        enqueueASR { [self] in
            let engine = recognizerEngine
            let tAsrStart = nowMs()
            // After a pause the remainder is often just room noise; skip it then. Without any
            // pause the whole recording is always recognized, so quiet speech is never dropped.
            let skip = rest.isEmpty || (segmented > 0 && !(detector?.containsSpeech(rest) ?? true))
            let last = skip ? "" : Intonation.markQuestion(recognizer?.transcribe(rest) ?? "", audio: rest,
                                                                    enabled: utterance.style.questionMark)
            let joined = PauseCutter.join(utterance.parts + [last], style: utterance.style)
            let replaced = vocabulary.apply(to: joined)
            // A trigger is matched as fixed by the dictionary, or as recognized.
            let text = snippets.match(replaced, joined) ?? replaced
            if text != replaced { Log.info("snippet: \(replaced)") }
            let tAsrEnd = nowMs()
            DispatchQueue.main.async { [self] in
                let tMain = nowMs()
                let audioSec = Double(samples.count) / 16_000
                let segments = String(
                    format: "segments=%d(%.1fs) last=%.1fs", utterance.segments, utterance.segmentAudio,
                    Double(rest.count) / 16_000)
                guard !text.isEmpty else {
                    Log.info(String(format: "audio=%.1fs asr=%.0fms (empty) %@", audioSec, tAsrEnd - tAsrStart, segments))
                    return
                }
                dictationCount += 1
                let id = dictationCount
                self.last = LastDictation(id: id, text: text, recognized: replaced, audio: samples, style: utterance.style, engine: engine, sent: send)
                paste(text, recognized: replaced, for: id, engine: engine, pressReturn: send) { [self] tPosted in
                    // lag = release event -> record queue handler; stop includes the post-roll; *Wait = time queued before the step ran
                    // (pasteWait includes waiting for a previous paste). posted = Cmd+V sent.
                    let timing = String(
                        format: "audio=%.1fs lag=%.0f stop=%.0f asrWait=%.0f asr=%.0f mainWait=%.0f paste=%.0f total=%.0fms",
                        audioSec, tHandled - tRelease, tStopped - tHandled, tAsrStart - tStopped,
                        tAsrEnd - tAsrStart, tMain - tAsrEnd, tPosted - tMain, tPosted - tRelease)
                    Log.info(tPosted < 0 ? "paste aborted text=\(text)" : "\(timing) \(segments) text=\(text)")
                    if tPosted >= 0 {
                        setStatus(String(format: "前回: %.0fms（%.1f秒の発話）", tPosted - tRelease, audioSec))
                    }
                }
            }
        }
    }

    // MARK: - Last dictation (Fn+V / Fn+Z / Fn+R)

    private func frontmostApp() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Main thread. Every paste goes through here, so `pasteCount` counts them all: a paste of
    /// anything else after the last dictation's makes it undeletable. The dictation's text counts as
    /// at the cursor only once the app has read it.
    /// `recognized` (see LastDictation) is what `text` came from; it becomes the last dictation's with it.
    private func paste(_ text: String, recognized: String, for id: Int, engine: Engine?, pressReturn: Bool = false,
                       deleteFirst: (() -> (count: Int, generation: Int)?)? = nil, onPosted: @escaping (Double) -> Void = { _ in }) {
        var count = 0
        // Taken just before the keys go out, so anything typed after them counts as an edit; when
        // deleting first, the one deletion was allowed on, so nothing in between is missed.
        var generation: Int?
        var app: pid_t?
        let deleteFirst = deleteFirst.map { allow in { () -> Int? in
            guard let allowed = allow() else { return nil }
            generation = allowed.generation
            return allowed.count
        } }
        inserter.insert(text, pressReturn: pressReturn, deleteFirst: deleteFirst, willSend: { [self] in
            if generation == nil { generation = hotkey?.inputGeneration ?? 0 }
            app = frontmostApp()
        }, afterDelete: deleteFirst == nil ? nil : { [self] done in
            // A key or click since deletion was allowed (counted by the tap up to our last
            // Delete): the cursor may have moved, so do not paste.
            guard let hotkey else { return done(false) }
            hotkey.afterPendingEvents { ok in done(ok && hotkey.inputGeneration == generation) }
        }, onPosted: { [self] posted in
            if posted >= 0 {
                pasteCount += 1
                count = pasteCount
                if last?.id == id {
                    last?.text = text
                    last?.recognized = recognized
                    last?.engine = engine
                    last?.paste = nil
                    last?.removed = false
                    last?.sent = pressReturn
                    last?.app = app
                    last?.generation = generation ?? 0
                }
            }
            onPosted(posted)
        }, onSettled: { [self] read in
            if read, count > 0, count == pasteCount, last?.id == id { last?.paste = count }
        })
    }

    /// Main thread, when a job that deletes the last paste gets its turn: whether it may, and if
    /// so it is no longer there to delete again.
    private func takeLastForDeletion() -> (count: Int, generation: Int)? {
        guard let current = last else { return nil }
        // A drag or click still in progress may yet move the cursor.
        guard NSEvent.pressedMouseButtons == 0 else {
            refuse(LastDictation.Refusal.edited.message)
            return nil
        }
        // Accessibility first: input arriving while it is asked is then still seen below.
        let caret = FocusedText.caretFollows(current.text)
        let generation = hotkey?.inputGeneration ?? 0
        let refusal = current.refusalToDelete(latestPaste: pasteCount, app: frontmostApp(),
                                              generation: generation, caretFollows: caret)
        if let refusal {
            refuse(refusal.message)
            return nil
        }
        last?.paste = nil
        return (current.text.count, generation)
    }

    /// Main thread.
    private func run(_ command: HotkeyMonitor.Command) {
        if command == .register { return registerWord() }
        guard let last else {
            refuse("まだ何も入力していません")
            return
        }
        switch command {
        case .repaste:
            paste(last.text, recognized: last.recognized, for: last.id, engine: last.engine) { posted in
                if posted >= 0 { Log.info("pasted again: \(last.text)") }
            }
        case .undo:
            let id = last.id
            inserter.insert("", deleteFirst: { [self] in
                guard self.last?.id == id else {
                    refuse("新しい入力があったので取り消しをやめました")
                    return nil
                }
                return takeLastForDeletion()?.count
            }, onPosted: { [self] posted in
                guard posted >= 0 else { return }
                Log.info("removed the last paste")
                if self.last?.id == id { self.last?.removed = true }
            })
        case .retry:
            retry(last)
        case .register:
            break
        }
    }

    /// Fn+D or the menu. The window takes the focus, so it opens only once a dictation still finishing
    /// has been pasted where it was meant to go: after the record queue (no post-roll pending), the ASR
    /// queue, the paste queue and the event tap (every key sent so far delivered).
    @objc private func registerWord() {
        let busy = "入力が終わってから登録してください"
        guard !retrying else { return refuse("認識し直している間は登録できません") }
        recordQueue.async { [self] in
            guard !recorder.isRunning, pendingFinish == nil else {
                return DispatchQueue.main.async { [self] in refuse(busy) }
            }
            asrQueue.async {
                DispatchQueue.main.async { [self] in
                    inserter.afterPending { [self] in
                        // No tap means no keys of ours were sent either.
                        guard let hotkey else { return vocabularyWindow.show(from: last?.recognized ?? "") }
                        hotkey.afterPendingEvents { [self] delivered in
                            guard delivered else { return refuse(busy) }
                            vocabularyWindow.show(from: last?.recognized ?? "")
                        }
                    }
                }
            }
        }
    }

    private func refuse(_ message: String) {
        Log.info("command refused: \(message)")
        setStatus(message)
        overlay.flash(message)
        NSSound.beep()
    }

    /// Main thread. Recognizes the last audio with the other model and, if it differs, swaps it in
    /// for the pasted text (or pastes it, when the old text was removed with Fn+Z). Whether the old
    /// text may be deleted is decided when the replacement's turn to paste comes.
    private func retry(_ target: LastDictation) {
        guard !retrying else { return }
        guard !target.audio.isEmpty, let engine = Engine.alternative(to: target.engine) else {
            refuse("認識し直せる別のモデルがありません")
            return
        }
        retrying = true
        let flash = overlay.flash("\(engine.title) で認識し直しています…", seconds: 30)
        retryQueue.async { [self] in
            let t = nowMs()
            let result = Result { () throws -> String in
                if retryDetector == nil { retryDetector = try? SpeechDetector(model: Paths.vadModel) }
                // The model dictation is using: run it where it lives rather than load a second
                // copy, one stretch at a time so a new dictation's segments can go in between.
                if asrQueue.sync(execute: { recognizerEngine == engine }) {
                    retryRecognizer = nil
                    return try Retranscriber.run(target.audio, detector: retryDetector, style: target.style) { audio in
                        try asrQueue.sync {
                            guard recognizerEngine == engine, let recognizer else { throw RetryError.modelChanged }
                            return try recognizer.recognize(audio)
                        }
                    }
                }
                if retryRecognizer?.engine != engine {
                    retryRecognizer = nil
                    let r = try engine.make()
                    retryRecognizer = (engine, r, 0)
                    Log.info("retry: loaded \(r.name) \(Int(nowMs() - t))ms")
                }
                retryRecognizer?.lastUse = nowMs()
                scheduleRetryUnload()
                return try Retranscriber.run(target.audio, detector: retryDetector, style: target.style, recognize: retryRecognizer!.recognizer.recognize)
            }.map { (raw: String) -> (recognized: String, text: String) in
                // The same dictionary and snippets as dictation, where they live (they keep the last good copy).
                asrQueue.sync {
                    let replaced = vocabulary.apply(to: raw)
                    return (recognized: replaced, text: snippets.match(replaced, raw) ?? replaced)
                }
            }
            let elapsed = nowMs() - t
            DispatchQueue.main.async { [self] in
                retrying = false
                overlay.hideFlash(flash)
                switch result {
                case .failure(let error):
                    Log.info("retry with \(engine) failed: \(error)")
                    refuse("\(engine.title) で認識できませんでした")
                case .success(let (recognized, text)):
                    Log.info(String(format: "retry %@ %.0fms: %@ -> %@", engine.rawValue, elapsed, target.text, text))
                    replace(target, with: text, recognized: recognized, engine: engine)
                }
            }
        }
    }

    /// Main thread.
    private func replace(_ target: LastDictation, with text: String, recognized: String, engine: Engine) {
        guard let current = last, current.id == target.id else {
            refuse("新しい入力があったので差し替えをやめました")
            return
        }
        guard !text.isEmpty else {
            refuse("\(engine.title) では何も認識されませんでした")
            return
        }
        if current.removed {
            paste(text, recognized: recognized, for: current.id, engine: engine) { [self] posted in
                if posted >= 0 { setStatus("\(engine.title) の結果を入力しました") }
            }
            return
        }
        if text == current.text {
            last?.engine = engine
            last?.recognized = recognized
            setStatus("\(engine.title) でも同じ結果でした")
            overlay.flash("同じ結果でした")
            return
        }
        let id = current.id
        paste(text, recognized: recognized, for: id, engine: engine, deleteFirst: { [self] in
            guard self.last?.id == id, self.last?.removed == false else {
                refuse("差し替えをやめました（\(engine.title): \(text)）")
                return nil
            }
            guard let allowed = takeLastForDeletion() else {
                setStatus("差し替えできませんでした（\(engine.title): \(text)）")
                return nil
            }
            return allowed
        }) { [self] posted in
            if posted >= 0 { setStatus("\(engine.title) で差し替えました") }
        }
    }

    private enum RetryError: Error { case modelChanged }

    /// Runs on `retryQueue`: frees the other model once it has gone unused for `retryKeepSeconds`.
    private func scheduleRetryUnload() {
        retryQueue.asyncAfter(deadline: .now() + retryKeepSeconds + 1) { [self] in
            guard let loaded = retryRecognizer, nowMs() - loaded.lastUse >= retryKeepSeconds * 1000 else { return }
            retryRecognizer = nil
            Log.info("retry: unloaded \(loaded.engine)")
        }
    }

    // MARK: - Setup

    /// Main thread. Loads on the ASR queue, so recordings already queued finish on the old model and
    /// the switch takes effect from the next one. The new model replaces the old one only after a
    /// successful warm-up; on failure the previous model stays in use.
    private func loadRecognizer(_ engine: Engine) {
        guard loadingEngine == nil else { return }
        loadingEngine = engine
        updateEngineMenu()
        setStatus("\(engine.title) を読み込み中…")
        // Fn+R may hold this model already: free that copy before loading, rather than keep two.
        // (Through retryQueue only by async; it calls into asrQueue with sync, never the reverse.)
        retryQueue.async { [self] in
            if retryRecognizer?.engine == engine { retryRecognizer = nil }
            asrQueue.async { [self] in load(engine) }
        }
    }

    /// Runs on `asrQueue`: the loading part of `loadRecognizer`.
    private func load(_ engine: Engine) {
        let result: Result<SpeechRecognizer, Error> = Result {
            let t = nowMs()
            let r = try engine.make()
            Log.info("loaded \(r.name) \(Int(nowMs() - t))ms")
            try r.warmUp()
            return r
        }
        if case .success(let r) = result {
            recognizer = r
            recognizerEngine = engine
            let policy = PreviewPolicy.measure(r)
            previewPolicy.withLock { $0 = policy }
            Log.info("live preview: \(policy)")
            DispatchQueue.main.async { [self] in
                previewSummary = policy.everyTicks == nil
                    ? "途中の表示: 確定部分のみ（この Mac では認識し直しが重いため）"
                    : String(format: "途中の表示: %.1f秒ごとに更新", Double(policy.everyTicks!) / 10)
                updateOptionsMenu()
            }
        }
        if detector == nil {
            do {
                detector = try SpeechDetector(model: Paths.vadModel)
            } catch {
                Log.info("VAD unavailable, recognizing every segment: \(error)")
            }
        }
        let usable = recognizer != nil
        if usable { recordQueue.async { self.ready = true } }
        DispatchQueue.main.async { [self] in
            loadingEngine = nil
            switch result {
            case .success:
                activeEngine = engine
                Engine.selected = engine
                modelLoaded = true
                if hotkey != nil { setStatus("待機中（\(engine.title)）") }
            case .failure(let error):
                Log.info("recognizer load failed: \(error)")
                let kept = activeEngine.map { "（\($0.title) のまま）" } ?? ""
                setStatus("\(engine.title) の読み込みに失敗\(usable ? kept : "")")
            }
            updateEngineMenu()
        }
    }

    private func updateEngineMenu() {
        settings.refresh()
        engineMenu.removeAllItems()
        for engine in Engine.allCases {
            var title = engine.isInstalled ? engine.title : "\(engine.title)（未取得）"
            if engine == loadingEngine { title += "（読み込み中）" }
            let enabled = engine.isInstalled && loadingEngine == nil
            let item = NSMenuItem(title: title, action: enabled ? #selector(selectEngine(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = engine.rawValue
            item.state = engine == activeEngine ? .on : .off
            engineMenu.addItem(item)
        }
    }

    private enum Option: String, CaseIterable {
        case liveText, pauseComma, questionMark, spokenNewline, autoSend, skipPostRollWhenDone, pauseMedia, backchannel, callWindow, callCompact, callOnTop

        var title: String {
            switch self {
            case .pauseComma: return "間で読点「、」を入れる"
            case .spokenNewline: return "「改行」「次の行」とだけ言うと改行"
            case .autoSend: return "Shiftを押しながら録音を終えると送信（Enter）"
            case .liveText: return "話している途中の文字を表示する"
            case .questionMark: return "語尾が上がったら「？」を付ける"
            case .skipPostRollWhenDone: return "話し終えてから録音を終えたときは待たない"
            case .pauseMedia: return "録音中は音楽や動画を一時停止する"
            case .backchannel: return "間で相槌を返す（イヤホンのときだけ）"
            case .callWindow: return "電話画面を出す（相手は unazc）"
            case .callCompact: return "電話画面をコンパクトに"
            case .callOnTop: return "電話画面を常に前面に"
            }
        }

        var isOn: Bool {
            get {
                switch self {
                case .pauseComma: return Options.pauseComma
                case .spokenNewline: return Options.spokenNewline
                case .autoSend: return Options.autoSend
                case .liveText: return Options.liveText
                case .questionMark: return Options.questionMark
                case .skipPostRollWhenDone: return Options.skipPostRollWhenDone
                case .pauseMedia: return Options.pauseMedia
                case .backchannel: return Options.backchannel
                case .callWindow: return Options.callWindow
                case .callCompact: return Options.callCompact
                case .callOnTop: return Options.callOnTop
                }
            }
            nonmutating set {
                switch self {
                case .pauseComma: Options.pauseComma = newValue
                case .spokenNewline: Options.spokenNewline = newValue
                case .autoSend: Options.autoSend = newValue
                case .liveText: Options.liveText = newValue
                case .questionMark: Options.questionMark = newValue
                case .skipPostRollWhenDone: Options.skipPostRollWhenDone = newValue
                case .pauseMedia: Options.pauseMedia = newValue
                case .backchannel: Options.backchannel = newValue
                case .callWindow: Options.callWindow = newValue
                case .callCompact: Options.callCompact = newValue
                case .callOnTop: Options.callOnTop = newValue
                }
            }
        }
    }

    private func updateOptionsMenu() {
        settings.refresh()
        registerItem.title = "直前の文字を辞書に登録…（\(Options.recordKeyTitle)+D）"
        if showingIdleHint { statusLine.title = idleHintText }
        optionsMenu.removeAllItems()
        for option in Option.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option.isOn ? .on : .off
            if option == .callCompact || option == .callOnTop { item.indentationLevel = 1 }
            optionsMenu.addItem(item)
            if option == .callOnTop {
                let current = Options.callOpacity
                let choices = Options.callOpacityChoices.contains(current)
                    ? Options.callOpacityChoices : (Options.callOpacityChoices + [current]).sorted(by: >)
                let opacity = NSMenuItem(title: "電話画面の不透明度", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for value in choices {
                    let choice = NSMenuItem(title: "\(Int((value * 100).rounded()))%", action: #selector(selectCallOpacity(_:)), keyEquivalent: "")
                    choice.target = self
                    choice.representedObject = value
                    choice.state = value == current ? .on : .off
                    submenu.addItem(choice)
                }
                opacity.submenu = submenu
                opacity.indentationLevel = 1
                optionsMenu.addItem(opacity)
            }
            if option == .liveText, !previewSummary.isEmpty {
                let note = NSMenuItem(title: previewSummary, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.indentationLevel = 1
                optionsMenu.addItem(note)
            }
        }
        optionsMenu.addItem(.separator())
        let recordKeysHeader = NSMenuItem(title: "録音キー（複数選べます）", action: nil, keyEquivalent: "")
        recordKeysHeader.isEnabled = false
        optionsMenu.addItem(recordKeysHeader)
        for key in Options.RecordKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(toggleRecordKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = Options.recordKeys.contains(key) ? .on : .off
            item.indentationLevel = 1
            optionsMenu.addItem(item)
        }
        optionsMenu.addItem(.separator())
        let keyHeader = NSMenuItem(title: "録音キーの使い方", action: nil, keyEquivalent: "")
        keyHeader.isEnabled = false
        optionsMenu.addItem(keyHeader)
        for mode in Options.RecordKeyMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectRecordKeyMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == Options.recordKeyMode ? .on : .off
            item.indentationLevel = 1
            optionsMenu.addItem(item)
        }
        optionsMenu.addItem(.separator())
        let micHeader = NSMenuItem(title: "使った後もマイクを開いておく（話し始めが切れない）", action: nil, keyEquivalent: "")
        micHeader.isEnabled = false
        optionsMenu.addItem(micHeader)
        let keepOpen = Options.micKeepOpenSeconds
        let keepChoices = Options.micKeepOpenChoices.contains(keepOpen)
            ? Options.micKeepOpenChoices : Options.micKeepOpenChoices + [keepOpen]
        for seconds in keepChoices {
            let title = Options.micKeepOpenTitle(seconds)
            let item = NSMenuItem(title: title, action: #selector(selectMicKeepOpen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == keepOpen ? .on : .off
            item.indentationLevel = 1
            optionsMenu.addItem(item)
        }
        optionsMenu.addItem(.separator())
        let header = NSMenuItem(title: "録音を終えた後も続ける時間", action: nil, keyEquivalent: "")
        header.isEnabled = false
        optionsMenu.addItem(header)
        let current = Options.postRollMs
        // A value set outside the menu (defaults write) is shown, checked, so the menu tells the truth.
        let choices = Options.postRollChoices.contains(current)
            ? Options.postRollChoices : (Options.postRollChoices + [current]).sorted()
        for ms in choices {
            let title = Options.postRollTitle(ms)
            let item = NSMenuItem(title: title, action: #selector(selectPostRoll(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ms
            item.state = ms == current ? .on : .off
            item.indentationLevel = 1
            optionsMenu.addItem(item)
        }
    }

    private func updateAppOptionsItem() {
        guard let app = frontApp.bundleID, app != Bundle.main.bundleIdentifier else {
            appOptionsItem.isHidden = true
            return
        }
        appOptionsItem.isHidden = false
        let name = frontApp.name ?? FrontApp.name(of: app)
        appOptionsItem.title = "「\(name)」での設定"
        let submenu = NSMenu()
        for option in Options.TextOption.allCases {
            let header = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            let current = Options.override(option, app: app)
            for value in [nil, true, false] as [Bool?] {
                let item = NSMenuItem(title: Self.overrideTitle(value, global: option.global),
                                      action: #selector(selectAppOverride(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = AppOverrideChoice(app: app, option: option, value: value)
                item.state = value == current ? .on : .off
                item.indentationLevel = 1
                submenu.addItem(item)
            }
        }
        appOptionsItem.submenu = submenu
    }

    static func overrideTitle(_ value: Bool?, global: Bool) -> String {
        switch value {
        case nil: return "全体の設定に従う（いまは\(global ? "オン" : "オフ")）"
        case true?: return "オン"
        case false?: return "オフ"
        }
    }

    private final class AppOverrideChoice: NSObject {
        let app: String, option: Options.TextOption, value: Bool?
        init(app: String, option: Options.TextOption, value: Bool?) {
            self.app = app
            self.option = option
            self.value = value
        }
    }

    /// Takes effect from the next dictation in that app.
    @objc private func selectAppOverride(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AppOverrideChoice else { return }
        Options.setOverride(choice.option, app: choice.app, choice.value)
        settings.refresh()
    }

    private func updateLoginItem() {
        settings.refresh()
        loginItem.state = LoginAgent.isEnabled ? .on : .off
    }

    @objc private func toggleLogin() {
        LoginAgent.setEnabled(!LoginAgent.isEnabled)
        updateLoginItem()
    }

    @objc private func selectMicKeepOpen(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        Options.micKeepOpenSeconds = seconds
        updateOptionsMenu()
        recordQueue.async { [self] in applyMicPolicy() }
    }

    /// Read by the event tap at each press. The last key cannot be turned off.
    @objc private func toggleRecordKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Options.RecordKey(rawValue: raw) else { return }
        var keys = Options.recordKeys
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        guard !keys.isEmpty else { return }
        Options.recordKeys = keys
        updateOptionsMenu()
        applyCallWindow()
    }

    /// Read by the event tap at each release, so a recording already latched still stops on the next press.
    @objc private func selectRecordKeyMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Options.RecordKeyMode(rawValue: raw) else { return }
        Options.recordKeyMode = mode
        updateOptionsMenu()
    }

    @objc private func selectPostRoll(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? Double else { return }
        Options.postRollMs = ms
        updateOptionsMenu()
    }

    /// Takes effect from the next dictation (the call screen at once); nothing needs reloading.
    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Option(rawValue: raw) else { return }
        option.isOn.toggle()
        updateOptionsMenu()
        if [.callWindow, .callCompact, .callOnTop].contains(option) { applyCallWindow() }
    }

    @objc private func selectCallOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Options.callOpacity = value
        updateOptionsMenu()
        applyCallWindow()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = Engine(rawValue: raw),
              engine != activeEngine else { return }
        loadRecognizer(engine)
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            Log.info("microphone access: \(ok)")
            guard ok, let self else { return }
            recordQueue.async { self.applyMicPolicy() }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        Log.info("accessibility trusted: \(AXIsProcessTrustedWithOptions(options))")
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setRecording(false)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let engineItem = NSMenuItem(title: "認識モデル", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        updateEngineMenu()
        let optionsItem = NSMenuItem(title: "オプション", action: nil, keyEquivalent: "")
        optionsItem.submenu = optionsMenu
        menu.addItem(optionsItem)
        updateOptionsMenu()
        menu.addItem(appOptionsItem)
        menu.addItem(NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",").withTarget(self))
        menu.addItem(loginItem)
        updateLoginItem()
        menu.addItem(registerItem)
        menu.addItem(NSMenuItem(title: "置き換え辞書を編集…", action: #selector(editVocabulary), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "定型文を編集…", action: #selector(editSnippets), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "ログを開く", action: #selector(openLog), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Never shown (the app has no Dock icon or menu bar of its own), but its key equivalents are
    /// what make ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z work in the text fields of our windows.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setRecording(_ on: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setRecording(on) }
            return
        }
        statusItem.button?.image = on
            ? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Unazc")
            : StatusIcon.idle
        statusItem.button?.contentTintColor = on ? .systemRed : nil
        if !on { overlay.hide() }
        if on, Options.backchannel { backchannel.prepare() }
        mediaPauser.recordingChanged(on)
        callWindow.setListening(on)
    }

    /// `idleHint`: the text is `idleHintText`, redrawn when the record key options change.
    private func setStatus(_ text: String, idleHint: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setStatus(text, idleHint: idleHint) }
            return
        }
        statusLine.title = text
        showingIdleHint = idleHint
    }

    private var idleHintText: String {
        Options.recordKeyMode == .toggle ? "待機中（\(Options.recordKeyTitle)を押して話す）" : "待機中（\(Options.recordKeyTitle)長押しで話す）"
    }

    @objc private func editVocabulary() {
        openEditable(Vocabulary.defaultURL, template: Vocabulary.template)
    }

    @objc private func editSnippets() {
        openEditable(Snippets.defaultURL, template: Snippets.template)
    }

    private func openEditable(_ url: URL, template: String) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.info("cannot create \(url.path): \(error)")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Unazc/unazc.log")
        NSWorkspace.shared.open(url)
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}

extension AppController: NSMenuDelegate {
    /// The agent can also be turned on or off from another copy or the CLI, so refresh on open.
    func menuWillOpen(_ menu: NSMenu) {
        updateLoginItem()
        updateAppOptionsItem()
    }
}
