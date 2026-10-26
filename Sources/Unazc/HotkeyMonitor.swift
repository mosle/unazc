import AppKit
import os

/// Push-to-talk on the Fn key via a CGEventTap.
///
/// Fn used as a modifier (Fn+arrow, Fn+Shift...) cancels instead of dictating. Esc while held
/// cancels and is swallowed, including its repeats and keyUp, so it does not reach the front app.
/// Fn+V / Fn+Z / Fn+R / Fn+D (no other modifier) act on the last dictation and are swallowed the same way.
/// In toggle mode (`Options.recordKeyMode`) a release can latch the recording: it then runs with Fn
/// up until the next Fn press stops it, or Esc cancels it. Keys typed meanwhile go to the app as usual.
/// Command keys on the stopping press are swallowed without acting, as they could not tell whether
/// they meant the dictation being finished or the one before.
/// The tap runs on its own thread so a busy main thread can neither delay timestamps nor time the
/// tap out; all key state below is touched only on that thread.
final class HotkeyMonitor {
    /// Tags events we synthesize (Cmd+V, Cmd+Z) so the tap does not treat them as user input.
    static let syntheticMarker: Int64 = 0x756E617A63 // "unazc"

    /// `time` is taken in the tap callback, before any main-queue delay (CGEvent timestamps
    /// are not reliably in ns on Apple Silicon).
    /// `send`: Shift was held at release with the auto-send option on.
    /// `reject`: the press started no recording, so its release must not latch one.
    enum Event { case press(time: Double, reject: () -> Void), release(time: Double, send: Bool), cancel, command(Command) }

    /// What Fn+key does to the last dictation.
    enum Command { case repaste, undo, retry, register }
    private static let commandKeys: [Int64: Command] = [9: .repaste, 6: .undo, 15: .retry, 2: .register] // V, Z, R, D

    private static let fnKeyCode: Int64 = 63 // kVK_Function
    private static let escKeyCode: Int64 = 53
    private static let shiftKeyCodes: Set<Int64> = [56, 60] // left, right
    private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    private let handler: (Event) -> Void
    private let queue: DispatchQueue
    private var tap: CFMachPort?
    private var thread: Thread?
    /// Fn is physically down and this press is still a dictation candidate.
    private var armed = false
    /// Fn is physically down (armed or already cancelled).
    private var fnDown = false
    /// When the armed press went down, for telling a tap from a hold.
    private var armedAt: Double = 0
    /// Counts presses, so a late rejection cannot touch a later press.
    private var pressID = 0
    /// The press whose recording goes on with Fn up until the next press, and the last press the app
    /// rejected. Locked since rejections come from the app's queue.
    private let latch = OSAllocatedUnfairLock(initialState: (latched: Int?.none, rejected: 0))
    private var latched: Bool { latch.withLock { $0.latched != nil } }
    /// Fn is down for the press that stopped a latched recording.
    private var stopping = false
    /// Swallow Esc until its keyUp after it was used to cancel.
    private var swallowingEsc = false
    /// Command keys pressed with Fn, swallowed until their keyUp.
    private var swallowedKeys: Set<Int64> = []

    /// Bumped on every key press that reaches an app and every click, in event order, so a click
    /// before Fn+Z is always counted before the command is handled. Deleting a paste is safe only
    /// while this has not moved since.
    private let inputCounter = OSAllocatedUnfairLock(initialState: 0)
    var inputGeneration: Int { inputCounter.withLock { $0 } }
    private func noteUserInput() { inputCounter.withLock { $0 += 1 } }

    /// Barriers: a swallowed F20 keyUp posted after our own keys. Events reach the tap in order, so
    /// when it arrives every user event posted before it has been counted.
    private static let barrierBase: Int64 = 0x7562 << 32 // "ub"
    private static let barrierKeyCode: CGKeyCode = 90 // kVK_F20
    private let barriers = OSAllocatedUnfairLock(initialState: (next: Int64(0), waiting: [Int64: () -> Void]()))

    /// Calls `done` on the main thread once the tap has seen everything posted before this call,
    /// or after `timeout` if the barrier never comes back (then with false).
    func afterPendingEvents(timeout: Double = 0.5, _ done: @escaping (Bool) -> Void) {
        let id = barriers.withLock { state -> Int64 in
            state.next = (state.next + 1) & 0xFFFF_FFFF
            state.waiting[state.next] = { DispatchQueue.main.async { done(true) } }
            return state.next
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.barrierKeyCode, keyDown: false) else {
            barriers.withLock { _ = $0.waiting.removeValue(forKey: id) }
            return DispatchQueue.main.async { done(false) }
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Self.barrierBase | id)
        event.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [barriers] in
            if barriers.withLock({ $0.waiting.removeValue(forKey: id) }) != nil { done(false) }
        }
    }

    /// `handler` runs on `queue`, in event order.
    init(queue: DispatchQueue, handler: @escaping (Event) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Returns false when the tap cannot be created (Accessibility not granted).
    func start() -> Bool {
        // Mouse buttons only to count them: a click or drag may move the cursor, which Fn+Z must
        // notice. Up too, since a click that started before a paste takes effect on release.
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "unazc.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    private func emit(_ event: Event) {
        queue.async { [handler] in handler(event) }
    }

    private func cancelIfArmed() {
        guard armed else { return }
        armed = false
        emit(.cancel)
    }

    private func cancelIfRecording() {
        cancelIfArmed()
        guard latch.withLock({ $0.latched.take() }) != nil else { return }
        emit(.cancel)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, userData & ~0xFFFF_FFFF == Self.barrierBase {
            barriers.withLock { $0.waiting.removeValue(forKey: userData & 0xFFFF_FFFF) }?()
            return nil
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Events were lost while disabled, so the Fn state is unknown: drop this press entirely.
            cancelIfRecording()
            fnDown = false
            stopping = false
            swallowingEsc = false
            swallowedKeys = []
            noteUserInput()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags
            if keyCode == Self.fnKeyCode {
                let down = flags.contains(.maskSecondaryFn)
                if down, !fnDown {
                    fnDown = true
                    // The press that ends a latched recording, whatever else is held. Stopping on
                    // the press rather than the release keeps the latency of the hold mode.
                    if latch.withLock({ $0.latched.take() }) != nil {
                        stopping = true
                        emit(.release(time: nowMs(), send: Options.autoSend && flags.contains(.maskShift)))
                        return Unmanaged.passUnretained(event)
                    }
                    // Fn pressed while another modifier is held is a shortcut, not dictation. With
                    // auto-send on, Shift may already be held: Shift then Fn starts a dictation that
                    // sends, and a re-press during the post-roll still cancels the pending finish.
                    let blocking = Options.autoSend ? Self.otherModifiers.subtracting(.maskShift) : Self.otherModifiers
                    if flags.intersection(blocking).isEmpty {
                        armed = true
                        armedAt = nowMs()
                        pressID += 1
                        let id = pressID
                        emit(.press(time: armedAt, reject: { [latch] in
                            latch.withLock { state in
                                state.rejected = id
                                if state.latched == id { state.latched = nil }
                            }
                        }))
                    }
                } else if !down, fnDown {
                    fnDown = false
                    stopping = false
                    if armed {
                        armed = false
                        let now = nowMs()
                        if Options.recordKeyMode.latches(heldMs: now - armedAt) {
                            let id = pressID
                            latch.withLock { state in
                                if state.rejected != id { state.latched = id }
                            }
                        } else {
                            emit(.release(time: now, send: Options.autoSend && flags.contains(.maskShift)))
                        }
                    }
                }
            } else if Options.autoSend, Self.shiftKeyCodes.contains(keyCode) {
                // Shift during dictation is the send gesture, read at release.
            } else {
                // Any other modifier changing while Fn is held (including Caps Lock either way)
                // means Fn is part of a shortcut.
                cancelIfArmed()
            }
        case .keyDown:
            if keyCode == Self.escKeyCode, armed || latched || swallowingEsc {
                swallowingEsc = true
                cancelIfRecording()
                return nil
            }
            if swallowedKeys.contains(keyCode) { return nil } // auto-repeat
            // Not a repeat: a key already down and delivered to the app before Fn keeps going there.
            if fnDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.flags.intersection(Self.otherModifiers).isEmpty, let command = Self.commandKeys[keyCode] {
                cancelIfArmed()
                swallowedKeys.insert(keyCode)
                if !stopping { emit(.command(command)) }
                return nil
            }
            cancelIfArmed()
            noteUserInput()
        case .keyUp:
            if keyCode == Self.escKeyCode, swallowingEsc {
                swallowingEsc = false
                return nil
            }
            if swallowedKeys.remove(keyCode) != nil { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            noteUserInput()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
