import AppKit

let args = CommandLine.arguments

/// CLI recognizer: a sherpa-onnx model dir if given, else UNAZC_ENGINE (reazon|reazonJaEn|kotoba), else the menu choice.
func cliRecognizer(_ dir: String?) throws -> SpeechRecognizer {
    if let dir {
        let threads = Int32(ProcessInfo.processInfo.environment["UNAZC_THREADS"] ?? "") ?? 4
        return try SherpaTransducerRecognizer(modelDir: URL(fileURLWithPath: dir), numThreads: threads)
    }
    return try (ProcessInfo.processInfo.environment["UNAZC_ENGINE"].flatMap(Engine.init) ?? Engine.selected).make()
}

// Benchmark without the GUI: Unazc --transcribe <audio> [sherpaModelDir]
if args.count >= 3, args[1] == "--transcribe" {
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: args[2]))
        var t = nowMs()
        let recognizer = try cliRecognizer(args.count >= 4 ? args[3] : nil)
        print(String(format: "load: %.0fms", nowMs() - t))
        try recognizer.warmUp()
        for run in 1...5 {
            t = nowMs()
            let text = recognizer.transcribe(samples)
            print(String(format: "run%d: audio=%.1fs asr=%.0fms %@", run, Double(samples.count) / 16_000, nowMs() - t, text))
        }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

// Compare whole vs pause-segmented recognition: Unazc --segmented <audio> [sherpaModelDir]
// Segments are cut as they would be live (checked every 100 ms on the audio so far).
if args.count >= 3, args[1] == "--segmented" {
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: args[2]))
        let recognizer = try cliRecognizer(args.count >= 4 ? args[3] : nil)
        try recognizer.warmUp()
        let detector = try? SpeechDetector(model: Paths.vadModel)
        let levels = PauseCutter.levels(samples)
        var after = 0
        var parts: [String] = []
        for end in stride(from: 5, through: levels.count, by: 5) {
            while let cut = PauseCutter.findCut(levels: Array(levels[..<end]), after: after) {
                let audio = Array(samples[after * PauseCutter.frameSize..<cut.frame * PauseCutter.frameSize])
                let speech = detector?.containsSpeech(audio) ?? true
                print(String(format: "  cut at %.2fs speech=%@", Double(cut.frame) * 0.02, speech ? "yes" : "no"))
                if speech { parts.append(recognizer.transcribe(audio)) }
                after = cut.frame
            }
        }
        var rest = Array(samples[(after * PauseCutter.frameSize)...])
        if after > 0, !(detector?.containsSpeech(rest) ?? true) { rest = [] }
        var t = nowMs()
        let last = rest.isEmpty ? "" : recognizer.transcribe(rest)
        let tLast = nowMs() - t
        t = nowMs()
        let whole = recognizer.transcribe(samples)
        let tWhole = nowMs() - t
        print(String(format: "whole: %.0fms %@", tWhole, whole))
        // Only the final segment's own ASR time; live, release also waits for queued segments.
        print(String(format: "segmented: final-segment asr %.1fs %.0fms %@", Double(rest.count) / 16_000, tLast, PauseCutter.join(parts + [last], style: Options.style(for: nil))))
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

// Check the replacement dictionary: Unazc --replace <text> [vocabFile]
if args.count >= 3, args[1] == "--replace" {
    let vocabulary = args.count >= 4 ? Vocabulary(url: URL(fileURLWithPath: args[3])) : Vocabulary()
    print(vocabulary.apply(to: args[2]))
    exit(0)
}

// Check end-of-speech detection: Unazc --tail <audio> [lookbackMs]
// Prints, every 100 ms, whether speech is still going on if the key were released there.
if args.count >= 3, args[1] == "--tail" {
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: args[2]))
        let lookback = Int(args.count >= 4 ? args[3] : "") ?? 800
        let minSilence = Float(ProcessInfo.processInfo.environment["UNAZC_TAIL_SILENCE"] ?? "") ?? SpeechDetector.tailMinSilence
        let detector = try SpeechDetector(model: Paths.vadModel, minSilence: minSilence)
        var line = ""
        for end in stride(from: 1_600, through: samples.count, by: 1_600) {
            let tail = Array(samples[max(0, end - lookback * 16)..<end])
            let t = nowMs()
            let speaking = detector.isSpeaking(atEndOf: tail)
            let loud = !PauseCutter.isNearNoiseFloor(levels: PauseCutter.levels(Array(samples[..<end])), tail: samples[max(0, end - 2_400)..<end])
            // S = VAD hears speech, L = VAD quiet but tail above the noise floor, - = ended,
            // ? = under 800 ms of audio, which the app does not judge (it keeps the post-roll).
            let mark = end < 800 * 16 ? "?" : speaking ? "S" : loud ? "L" : "-"
            line += String(format: "%.1f:%@(%.0fms) ", Double(end) / 16_000, mark, nowMs() - t)
        }
        print(line)
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

// Live preview policy this Mac would get: Unazc --speed [sherpaModelDir] (UNAZC_THREADS to simulate a slower Mac)
if args.count >= 2, args[1] == "--speed" {
    do {
        let recognizer = try cliRecognizer(args.count >= 3 ? args[2] : nil)
        try recognizer.warmUp()
        for _ in 1...3 { print("\(recognizer.name): \(PreviewPolicy.measure(recognizer, always: true))") }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

// Check question detection: Unazc --intonation <audio>...
if args.count >= 3, args[1] == "--intonation" {
    for path in args.dropFirst(2) {
        do {
            let samples = try loadAudioFile(URL(fileURLWithPath: path))
            let t = nowMs()
            let track = Intonation.pitchTrack(samples.suffix(32_000)[...])
            let rise = Intonation.endRise(track: track)
            let voiced = track.compactMap { $0 }.count
            print(String(format: "%@: rise=%@ voiced=%d/%d (%.1fms)", (path as NSString).lastPathComponent,
                         rise.map { String(format: "%+.1fst", $0) } ?? "n/a", voiced, track.count, nowMs() - t))
        } catch {
            print("error: \(error)")
        }
    }
    exit(0)
}

// Show the live overlay with sample text for a few seconds: Unazc --overlay-demo
if args.count >= 2, args[1] == "--overlay-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = LiveOverlay()
    overlay.show(session: 1)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let long = String(repeating: "再利用可能なようにコンポーネントにして、", count: 12)
        overlay.update(session: 1, committed: long, full: long + "コンシューマーに合わせて")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    app.run()
}

// Show the settings window for a few seconds: Unazc --settings-demo. Options it changes are stored;
// the login item is only pretended.
if args.count >= 2, args[1] == "--settings-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let settings = SettingsWindow(actions: .init(engines: { (Engine.selected, nil) }, selectEngine: { _ in },
                                                 optionsChanged: {}, micPolicyChanged: {}, isLoginEnabled: { false }, setLogin: { _ in },
                                                 editVocabulary: {}, editSnippets: {}, openLog: {}))
    settings.show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}

// Show the call screen, full then compact, nodding: Unazc --call-demo
if args.count >= 2, args[1] == "--call-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let call = CallWindow()
    call.apply(visible: true, onTop: true, opacity: 1, compact: false, recordKey: "Fn")
    call.setListening(true)
    for (i, compact) in [false, true].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) {
            call.apply(visible: true, onTop: true, opacity: 1, compact: compact, recordKey: "Fn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3 + 1) { call.nod() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}

// Turn the login agent on or off without the menu: Unazc.app/Contents/MacOS/Unazc --login-agent on|off|status
// "off" also stops the app if launchd is running it.
if args.count >= 2, args[1] == "--login-agent" {
    let command = args.count == 3 ? args[2] : ""
    guard ["on", "off", "status"].contains(command) else {
        print("usage: Unazc --login-agent on|off|status")
        exit(2)
    }
    let ok = command == "status" || LoginAgent.setEnabled(command == "on")
    print("login agent: \(LoginAgent.isEnabled ? "on" : "off")" + (ok ? "" : " (failed; see the log)"))
    Log.flush()
    exit(ok ? 0 : 1)
}

guard LoginAgent.shouldRun() else {
    Log.flush()
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
