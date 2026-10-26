import AppKit
import CoreAudio

/// Pauses whatever is playing while dictating and resumes it after (see `Options.pauseMedia`).
///
/// Since macOS 15.4 an app cannot ask the Now Playing app whether it plays (MediaRemote answers
/// nothing), so this asks Core Audio whether another process is sending sound out, and if so presses
/// the play/pause media key. The key toggles, so it is pressed only when something plays, and again
/// at the end only if it was pressed at the start. Players such as Spotify stop their output at once
/// on pause; an app still holding the output after pausing, or a call app, could be taken for
/// playing, and the key would then start the Now Playing app instead.
final class MediaPauser {
    /// The resume waits this long, so a dictation that follows at once finds the music still
    /// paused instead of catching the player between the key and its sound coming back.
    private static let resumeDelay = 0.6
    /// After a resume, a player is taken as playing for this long even before its output shows.
    private static let resumeSettle = 2.0

    private let queue = DispatchQueue(label: "unazc.media")
    // On `queue`:
    /// The key was pressed to pause and not yet to resume.
    private var paused = false
    private var pendingResume: DispatchWorkItem?
    private var resumedAt: DispatchTime?
    /// The app is quitting: pause no more.
    private var closed = false

    /// Called on every change of the recording state, in order.
    func recordingChanged(_ on: Bool) {
        queue.async { [self] in
            if on {
                // Turned off meanwhile: the pending resume goes out as planned.
                guard Options.pauseMedia else { return }
                if let pending = pendingResume {
                    // Recording again before the resume went out: the music simply stays paused.
                    pending.cancel()
                    pendingResume = nil
                    return
                }
                // A re-press within the post-roll turns recording on again: already paused.
                guard !paused, !closed, justResumed() || Self.othersPlaying() else { return }
                paused = true
                Self.pressPlayPause()
                Log.info("media paused")
            } else {
                guard paused, pendingResume == nil else { return }
                let item = DispatchWorkItem { [self] in
                    pendingResume = nil
                    resume()
                }
                pendingResume = item
                queue.asyncAfter(deadline: .now() + Self.resumeDelay, execute: item)
            }
        }
    }

    /// Before the app exits: resumes at once what it paused, and waits until the key is sent.
    func restoreBeforeExit() {
        queue.sync {
            closed = true
            pendingResume?.cancel()
            pendingResume = nil
            resume()
        }
    }

    /// On `queue`.
    private func resume() {
        guard paused else { return }
        paused = false
        resumedAt = .now()
        Self.pressPlayPause()
        Log.info("media resumed")
    }

    /// On `queue`.
    private func justResumed() -> Bool {
        guard let resumedAt else { return false }
        return DispatchTime.now() < resumedAt + Self.resumeSettle
    }

    private static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        s.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }

    /// Whether a process other than this one is running audio output. The process objects exist
    /// from macOS 14.2; on earlier systems the query fails and this says no.
    private static func othersPlaying() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: fourCC("prs#"), // kAudioHardwarePropertyProcessObjectList
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).contains { id in
            guard let pid = value(id, "ppid"), pid_t(bitPattern: pid) != me else { return false } // kAudioProcessPropertyPID
            return value(id, "piro") == 1 // kAudioProcessPropertyIsRunningOutput
        }
    }

    private static func value(_ id: AudioObjectID, _ selector: String) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: fourCC(selector),
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The play/pause key as the keyboard sends it: a system-defined event, down then up.
    private static func pressPlayPause() {
        let playKey = 16 // NX_KEYTYPE_PLAY
        for state in [0xA, 0xB] { // key down, key up
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: playKey << 16 | state << 8, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
