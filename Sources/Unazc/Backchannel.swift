import AVFoundation
import CoreAudio

/// Backchannel replies (相槌): a short 「うん」 in the user's ears at the pauses while they dictate.
/// Played only through headphones: from speakers the microphone would pick it up and it would be
/// typed. Sounds in `userDirectory` replace the bundled ones (made by `scripts/make-backchannel.py`).
final class Backchannel {
    enum Kind: String, CaseIterable { case ack, cont, q }

    static let userDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Unazc/backchannel")
    static let bundledDirectory = Bundle.main.resourceURL?.appendingPathComponent("backchannel")

    /// Endings that leave the sentence open (「〜けど」「〜て」): a short 「うん」 to say go on.
    private static let openEndings = ["けど", "けれど", "が", "て", "で", "し", "から", "ので", "たら", "ば"]

    /// Which reply suits a stretch that just ended, or nil to stay quiet. People do not answer every
    /// pause, so some are skipped (`roll` in 0..<1), and never two within `minGap` seconds. Plain
    /// 「うん」 is mixed with 「へぇ」「なるほど」, or it sounds like a machine that only says うん.
    static func choose(text: String, stretchSeconds: Double, sinceLast: Double, roll: Double) -> Kind? {
        let bare = text.trimmingCharacters(in: .whitespaces)
        guard !bare.isEmpty, sinceLast >= minGap else { return nil }
        // Asked something, a listener mostly just agrees (「うん」); 「うーん」 now and then. The rise
        // that marks a question is easily misheard, so it only tilts the choice.
        if bare.hasSuffix("？") || bare.hasSuffix("?") { return roll < 0.5 ? .ack : roll < 0.8 ? .q : nil }
        if stretchSeconds >= 3 { return roll < 0.8 ? .cont : nil }
        if openEndings.contains(where: { bare.hasSuffix($0) }) { return roll < 0.5 ? .ack : roll < 0.8 ? .cont : nil }
        return roll < 0.35 ? .ack : roll < 0.6 ? .cont : nil
    }

    static let minGap = 1.5

    /// Main thread only, from here down.
    private var players: [Kind: [AVAudioPlayer]] = [:]
    /// The user folder's modification date at the last load; nil before the first.
    private var loadedStamp: Date??
    /// Kept by file, so a reload that reorders the sounds does not let it repeat.
    private var lastPlayed: URL?
    private var headphonesLogged: Bool?
    private var outputWatch: Timer?

    /// Loads the sounds ahead of the first reply (call when recording starts), so loading does not
    /// push a reply past its moment.
    func prepare() { reloadIfChanged() }

    /// Plays a reply unless, by the moment it would start, `deadline` (in `nowMs`) has passed,
    /// `stillWanted` says no, or the output is no longer headphones. Stops it if the output stops
    /// being headphones while it plays. Returns whether it started.
    @discardableResult
    func play(_ kind: Kind, deadline: Double, stillWanted: () -> Bool) -> Bool {
        reloadIfChanged()
        guard let choices = players[kind], !choices.isEmpty else { return false }
        let fresh = choices.filter { $0.url != lastPlayed }
        let player = (fresh.isEmpty ? choices : fresh).randomElement()!
        let headphones = OutputRoute.isHeadphones()
        if headphonesLogged != headphones {
            headphonesLogged = headphones
            Log.info(headphones ? "backchannel: headphones, replying" : "backchannel: not headphones, staying quiet")
        }
        guard headphones, nowMs() < deadline, stillWanted() else { return false }
        player.currentTime = 0
        player.volume = Float(Options.backchannelVolume)
        guard player.play() else { return false }
        lastPlayed = player.url
        watchOutput()
        return true
    }

    /// Unplugging headphones moves playback to the speakers, which the microphone hears: checked
    /// every 50 ms while anything plays.
    private func watchOutput() {
        guard outputWatch == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let playing = players.values.joined().filter(\.isPlaying)
            if playing.isEmpty || !OutputRoute.isHeadphones() {
                if !playing.isEmpty {
                    playing.forEach { $0.stop() }
                    Log.info("backchannel: output left headphones, stopped")
                }
                timer.invalidate()
                outputWatch = nil
            }
        }
        // Common modes, so it keeps checking while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        outputWatch = timer
    }

    /// Re-reads the user folder when it changes, so sounds added later are picked up. The bundled
    /// sounds are used while the user folder holds none.
    private func reloadIfChanged() {
        let fm = FileManager.default
        let stamp = (try? fm.attributesOfItem(atPath: Self.userDirectory.path)[.modificationDate]) as? Date
        if let loadedStamp, loadedStamp == stamp { return }
        loadedStamp = stamp
        let user = Self.sounds(in: Self.userDirectory)
        let files = user.isEmpty ? Self.bundledDirectory.map(Self.sounds) ?? [] : user
        players = [:]
        for (kind, url) in files {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[kind, default: []].append(player)
            } catch {
                Log.info("backchannel: cannot play \(url.lastPathComponent): \(error)")
            }
        }
        Log.info("backchannel: \(user.isEmpty ? "bundled" : "user") " + Kind.allCases.map { "\($0.rawValue)=\(players[$0]?.count ?? 0)" }.joined(separator: " "))
    }

    static func sounds(in directory: URL) -> [(Kind, URL)] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
                return Kind.allCases.first { url.lastPathComponent.hasPrefix("\($0.rawValue)-") }.map { ($0, url) }
            }
    }
}

enum OutputRoute {
    /// Headphones or earphones: the built-in jack, Bluetooth or USB. Speakers, displays (HDMI,
    /// DisplayPort), AirPlay and virtual devices are not, since the microphone may hear those.
    /// A Bluetooth or USB speaker cannot be told apart and counts as headphones.
    static func isHeadphones() -> Bool {
        guard let device = defaultOutput() else { return false }
        switch transportType(device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource(device) == fourCC("hdpn")
        default:
            return false
        }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func dataSource(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
