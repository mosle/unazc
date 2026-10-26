import CoreAudio
import Foundation

/// Tells the user, early in a recording, when the microphone gives nothing: no audio arrives (a
/// dead or disconnected device), or it arrives as digital silence (muted input, or microphone
/// access denied, which macOS delivers as zeros).
enum MicCheck {
    /// How long after the press the check runs: long enough for a slow device to open.
    static let afterSeconds = 1.2
    /// Below any real microphone's noise floor; only digital silence is this quiet.
    static let silentLevel: Float = 1e-6

    /// The warning for a recording that has run `elapsedMs` (plus the pre-roll it began with) and
    /// holds `frames` 20 ms frames whose loudest RMS is `peak`; nil when the microphone works.
    static func problem(frames: Int, peak: Float, elapsedMs: Double, device: String?) -> String? {
        let mic = device.map { "マイク（\($0)）" } ?? "マイク"
        // Opening a device can take ~0.4 s, so only a far shortfall means audio is not arriving.
        if Double(frames) < elapsedMs / 20 / 4 {
            return "\(mic)から音が届いていません"
        }
        if peak < silentLevel {
            return "\(mic)の音が無音です。ミュートやマイクの許可を確認してください"
        }
        return nil
    }

    /// The name of the default input device, e.g. "MacBook Proのマイク".
    static func inputDeviceName() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
