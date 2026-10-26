import AVFoundation
import UnazcObjC

/// Captures the default input and converts it to 16 kHz mono float as it arrives.
///
/// The input stream can stay open between recordings (`openStream()` / `shutdown()`), since opening
/// a device can take a few hundred ms and speech in that time is lost. While open and idle only the
/// last `preRollMs` is kept, and a recording on an open stream begins with it, so a word said
/// together with the key press is complete.
final class AudioRecorder {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    static let preRollMs = 200.0

    /// Replaced when the input device or its format changes: a reused engine keeps the old format
    /// and installing a tap with it raises. Only touched from the caller's (record) queue.
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    // Guarded by `lock`. Notifications and tap callbacks carry the engine / recording they belong to
    // and are ignored once that one is no longer current, so a late one cannot touch a new recording.
    private var configChanged = false
    private var currentEngine: ObjectIdentifier?
    private var generation = 0
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    /// RMS of each completed 20 ms frame, accumulated while recording so release never rescans all PCM.
    private var frameLevels: [Float] = []
    /// Timeline of converted audio: capture time (ms, nowMs() clock) of the first input sample fed
    /// to the converter since it was (re)started, and the samples it has put out since. Their end
    /// is `streamOrigin + streamOutput / 16`, so audio still held inside the resampler is never
    /// mistaken for delivered audio. If the anchoring buffer had no host time the origin stays nil
    /// until the next re-anchor, so callers fall back to the full post-roll.
    private var anchored = false
    private var streamOrigin: Double?
    private var streamOutput = 0
    /// Whether tap audio belongs to a recording; when false only the last `preRollMs` is kept.
    private var recording = false
    /// Diagnostics on the last tap buffer, including how late it arrived after capture (under `lock`).
    private var bufferFrames: AVAudioFrameCount = 0
    private var bufferRate: Double = 0
    private var bufferDelayMs: Double = 0
    /// A recording is in progress (start() ... takeSamples()).
    private(set) var isRunning = false
    /// The input stream is open (openStream() ... shutdown()). Confined to the caller's queue.
    private(set) var isStreaming = false
    /// Called (on an arbitrary thread) when the device or its format changes.
    var onConfigurationChange: (() -> Void)?

    enum RecorderError: Error { case noInputDevice, converterUnavailable }

    init() {
        observeConfiguration()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func observeConfiguration() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        let id = ObjectIdentifier(engine)
        lock.withLock { currentEngine = id }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let current = lock.withLock { () -> Bool in
                guard self.currentEngine == id else { return false }
                self.configChanged = true
                return true
            }
            Log.info("audio configuration changed")
            if current { self.onConfigurationChange?() }
        }
    }

    private func rebuildEngine() {
        _ = UnazcStopInput(engine)
        engine = AVAudioEngine()
        observeConfiguration()
    }

    /// The device or its format changed since the stream was opened; it must be reopened.
    var needsRebuild: Bool { lock.withLock { configChanged } }

    /// Opens the input; with `recording` false audio is kept only as pre-roll until `start()`.
    func openStream(recording startRecording: Bool = false) throws {
        guard !isStreaming else { return }
        var input = engine.inputNode
        let stale = lock.withLock { () -> Bool in
            defer { configChanged = false }
            return configChanged
        }
        if stale || input.inputFormat(forBus: 0).sampleRate != input.outputFormat(forBus: 0).sampleRate {
            Log.info("rebuilding audio engine")
            rebuildEngine()
            input = engine.inputNode
        }
        let hardwareFormat = input.inputFormat(forBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        // Installing a tap on an invalid format raises an Objective-C exception Swift cannot catch.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        let gen = lock.withLock { () -> Int in
            generation += 1
            samples.removeAll(keepingCapacity: true)
            frameLevels.removeAll(keepingCapacity: true)
            anchored = false
            streamOrigin = nil
            streamOutput = 0
            // Set before the tap exists, so its very first buffer already counts as recorded.
            recording = startRecording
            self.converter = converter
            return generation
        }
        var error: NSError?
        let ok = UnazcStartInputTap(engine, inputFormat, 1024, { [weak self] buffer, when in
            self?.append(buffer, at: when, generation: gen)
        }, &error)
        if !ok {
            lock.withLock {
                self.converter = nil
                self.recording = false
                // Start fresh next time rather than retrying a broken engine.
                self.configChanged = true
            }
            throw error ?? RecorderError.noInputDevice
        }
        isStreaming = true
    }

    /// Starts a recording, opening the input first if it is not open.
    func start() throws {
        guard !isRunning else { return }
        // A stream whose device changed (possibly during the last recording) is dead; reopen.
        if isStreaming, needsRebuild { shutdown() }
        if isStreaming {
            lock.withLock {
                // Idle audio is already trimmed to the pre-roll; it opens the recording.
                let preRoll = samples
                samples.removeAll(keepingCapacity: true)
                frameLevels.removeAll(keepingCapacity: true)
                recording = true
                appendLocked(preRoll)
            }
        } else {
            try openStream(recording: true)
        }
        isRunning = true
    }

    /// Ends the recording and returns its samples. The input stays open (back to pre-roll only);
    /// call `shutdown()` to close it, after recognition has been queued.
    func takeSamples() -> [Float] {
        guard isRunning else { return [] }
        isRunning = false
        return lock.withLock {
            // The resampler holds back a few frames; drain them so the end of the utterance survives.
            if let converter {
                while true {
                    guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: 1024) else { break }
                    var error: NSError?
                    let status = converter.convert(to: out, error: &error) { _, inStatus in
                        inStatus.pointee = .endOfStream
                        return nil
                    }
                    appendLocked(out)
                    if status != .haveData || out.frameLength == 0 { break }
                }
                // End of stream leaves the converter finished; reset it for the idle audio after,
                // and take a new origin from the next buffer since the timeline restarts.
                converter.reset()
                anchored = false
            }
            recording = false
            let taken = samples
            samples.removeAll(keepingCapacity: true)
            frameLevels.removeAll(keepingCapacity: true)
            return taken
        }
    }

    /// Closes the input stream (ending any recording without returning it).
    func shutdown() {
        guard isStreaming else { return }
        isRunning = false
        // Tap callbacks still arriving are dropped from here on.
        lock.withLock {
            converter = nil
            recording = false
            samples.removeAll()
            frameLevels.removeAll()
        }
        if !UnazcStopInput(engine) {
            Log.info("audio engine did not stop cleanly; rebuilding before next use")
            lock.withLock { configChanged = true }
        }
        isStreaming = false
    }

    /// A pause after frame `after` where the recording so far can be cut, with that segment's audio.
    func takeSegment(after: Int) -> (cut: PauseCutter.Cut, audio: [Float])? {
        // Search outside the lock so the audio thread is never held up by it.
        let levels: [Float]? = lock.withLock { recording ? frameLevels : nil }
        guard let levels, let cut = PauseCutter.findCut(levels: levels, after: after) else { return nil }
        let n = PauseCutter.frameSize
        // Frames only grow during a recording, so the range found above is still valid.
        return lock.withLock { (cut, Array(samples[after * n..<cut.frame * n])) }
    }

    /// The pause the recording is in right now (see PauseCutter.trailingPause).
    func trailingPause(after frame: Int) -> (start: Int, silentFrames: Int, voicedFrames: Int)? {
        let levels: [Float]? = lock.withLock { recording ? frameLevels : nil }
        return levels.flatMap { PauseCutter.trailingPause(levels: $0, after: frame) }
    }

    /// Diagnostics for the log: when capture began (nowMs() clock), and the last tap buffer.
    /// `firstCapture` is nil until the recording has a timeline.
    func captureInfo() -> (firstCapture: Double?, frames: AVAudioFrameCount, rate: Double, delayMs: Double) {
        lock.withLock {
            let first = recording && anchored ? streamOrigin.map { $0 + Double(streamOutput - samples.count) / 16 } : nil
            return (first, bufferFrames, bufferRate, bufferDelayMs)
        }
    }

    /// Whether the newest `tailMs` of the recording is near its own noise floor (see PauseCutter).
    func tailNearNoiseFloor(tailMs: Double) -> Bool {
        let (levels, tail): ([Float], [Float]) = lock.withLock {
            recording ? (frameLevels, Array(samples.suffix(Int(tailMs * 16)))) : ([], [])
        }
        return PauseCutter.isNearNoiseFloor(levels: levels, tail: tail[...])
    }

    /// The 20 ms frames recorded so far and the loudest one's RMS (see MicCheck); nil when not recording.
    func inputLevel() -> (frames: Int, peak: Float)? {
        let levels: [Float]? = lock.withLock { recording ? frameLevels : nil }
        return levels.map { ($0.count, $0.max() ?? 0) }
    }

    /// The recording from frame `frame` (20 ms frames) to now; empty when not recording.
    func audio(fromFrame frame: Int) -> [Float] {
        lock.withLock {
            let start = frame * PauseCutter.frameSize
            return recording && start < samples.count ? Array(samples[start...]) : []
        }
    }

    /// The newest `ms` of delivered audio (less if the recording is shorter).
    func recentSamples(ms: Double) -> [Float] {
        lock.withLock { recording ? Array(samples.suffix(Int(ms * 16))) : [] }
    }

    /// Whether audio captured up to `time` (nowMs() clock) has come out of the resampler into `samples`.
    func hasCaptured(through time: Double) -> Bool {
        lock.withLock {
            guard recording, anchored, let origin = streamOrigin else { return false }
            return origin + Double(streamOutput) / 16 >= time
        }
    }

    /// True when the last `tailMs` of delivered audio is quiet both relative to the speech so far and
    /// in absolute terms. Only call once `hasCaptured(through:)` covers the release, so a syllable
    /// still in the pipeline cannot be judged silent. When unsure it returns false.
    func tailIsSilent(tailMs: Double, ratio: Float, absolute: Float) -> Bool {
        let n = PauseCutter.frameSize
        let tailCount = Int(tailMs * 16)
        let (levels, tailFrames): ([Float], [Float]) = lock.withLock {
            guard recording, samples.count >= tailCount * 2 else { return ([], []) }
            // Sub-frames end exactly at the newest sample so nothing recent is skipped.
            let tail = stride(from: samples.count, to: samples.count - tailCount, by: -n).map { end in
                PauseCutter.rms(samples[max(end - n, samples.count - tailCount)..<end])
            }
            return (frameLevels, tail)
        }
        guard !levels.isEmpty, let tail = tailFrames.max() else { return false }
        let speech = levels.sorted()[levels.count * 9 / 10]
        let silent = tail < speech * ratio && tail < absolute
        Log.info(String(format: "tail level=%.4f speech=%.4f silent=%@", tail, speech, silent ? "yes" : "no"))
        return silent
    }

    private func append(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, generation gen: Int) {
        // Serialized with takeSamples() so a late tap callback cannot race the drain.
        lock.withLock {
            guard gen == generation, let converter else { return }
            // Host time is mach absolute time, the same clock nowMs() reads.
            if !anchored {
                anchored = true
                streamOrigin = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) * 1000 : nil
                streamOutput = 0
            }
            bufferFrames = buffer.frameLength
            bufferRate = buffer.format.sampleRate
            if when.isHostTimeValid {
                let end = AVAudioTime.seconds(forHostTime: when.hostTime) * 1000 + Double(buffer.frameLength) / buffer.format.sampleRate * 1000
                bufferDelayMs = nowMs() - end
            }
            let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil {
                streamOutput += Int(out.frameLength)
                appendLocked(out)
            }
            if !recording {
                let keep = Int(Self.preRollMs * 16)
                if samples.count > keep { samples.removeFirst(samples.count - keep) }
            }
        }
    }

    private func appendLocked(_ out: AVAudioPCMBuffer) {
        guard let data = out.floatChannelData, out.frameLength > 0 else { return }
        appendLocked(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    private func appendLocked<S: Sequence>(_ new: S) where S.Element == Float {
        samples.append(contentsOf: new)
        guard recording else { return }
        let n = PauseCutter.frameSize
        while (frameLevels.count + 1) * n <= samples.count {
            let start = frameLevels.count * n
            frameLevels.append(PauseCutter.rms(samples[start..<start + n]))
        }
    }
}

/// Reads any audio file as 16 kHz mono float (used by the --transcribe benchmark).
func loadAudioFile(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let converter = AVAudioConverter(from: file.processingFormat, to: AudioRecorder.targetFormat)!
    let ratio = 16_000 / file.processingFormat.sampleRate
    let out = AVAudioPCMBuffer(pcmFormat: AudioRecorder.targetFormat, frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 32)!
    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return inBuf
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}
