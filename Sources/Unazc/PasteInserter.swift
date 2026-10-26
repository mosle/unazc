import AppKit

/// Inserts text at the cursor of any app by pasting, then puts the user's clipboard back.
///
/// The text is put on the clipboard as a promise, so the user's clipboard comes back only after
/// the target app has actually read it; a fixed timer would paste the old clipboard into a slow app.
/// Inserts are serialized so texts never overwrite each other mid-paste. Main thread only.
final class PasteInserter {
    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private let pasteboard: NSPasteboard
    /// Sends one key press; replaced in tests.
    private let pressKey: (CGKeyCode, CGEventFlags) -> Void
    /// Marks our write so clipboard managers skip it (nspasteboard.org convention).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Restore no earlier than this after Cmd+V, and this long after the app's read.
    private let restoreDelay: TimeInterval
    private let afterRead: TimeInterval = 0.05
    /// If the app never reads (it ignored Cmd+V), restore anyway after this.
    private let readTimeout: TimeInterval = 2.0
    private struct Job {
        let text: String
        let pressReturn: Bool
        let deleteFirst: (() -> Int?)?
        let willSend: () -> Void
        let afterDelete: ((@escaping (Bool) -> Void) -> Void)?
        let onPosted: (Double) -> Void
        let onSettled: (Bool) -> Void
    }
    /// A paste, or a call that waits for the pastes queued before it.
    private enum Entry { case job(Job), barrier(() -> Void) }
    private var queue: [Entry] = []
    /// Gap between Cmd+V and Return, so apps that paste asynchronously (Electron, terminals)
    /// have the text in place before it is sent.
    private let returnDelay: TimeInterval = 0.08
    private var busy = false
    /// Kept until the clipboard is restored.
    private var promise: PromisedText?

    init(restoreDelay: TimeInterval = 0.15, pasteboard: NSPasteboard = .general,
         pressKey: @escaping (CGKeyCode, CGEventFlags) -> Void = PasteInserter.postKey) {
        self.restoreDelay = restoreDelay
        self.pasteboard = pasteboard
        self.pressKey = pressKey
    }

    /// `onPosted` receives the nowMs() at which Cmd+V was sent, or -1 if the paste was aborted.
    /// `deleteFirst` runs at the last moment before anything is sent and returns how many Deletes
    /// to press first (with empty `text`, only that), or nil to abort. Deciding then, not when
    /// queued, means nothing typed while it waited can be deleted by mistake.
    /// `onSettled` runs once the clipboard is back: true if the text was read (or there was none
    /// to read), false if it never was or the job was aborted.
    /// `afterDelete` runs once the Deletes are out and must call back (on the main thread) before
    /// the paste goes on; false aborts it.
    func insert(_ text: String, pressReturn: Bool = false, deleteFirst: (() -> Int?)? = nil, willSend: @escaping () -> Void = {},
                afterDelete: ((@escaping (Bool) -> Void) -> Void)? = nil,
                onPosted: @escaping (Double) -> Void = { _ in }, onSettled: @escaping (Bool) -> Void = { _ in }) {
        queue.append(.job(Job(text: text, pressReturn: pressReturn, deleteFirst: deleteFirst, willSend: willSend,
                              afterDelete: afterDelete, onPosted: onPosted, onSettled: onSettled)))
        if !busy { next() }
    }

    /// Calls `done` once every paste queued so far is over, clipboard restored. For taking the
    /// focus away from the app without a paste still on its way there.
    func afterPending(_ done: @escaping () -> Void) {
        queue.append(.barrier(done))
        if !busy { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            busy = false
            return
        }
        busy = true
        let job: Job
        switch queue.removeFirst() {
        case .job(let queued): job = queued
        case .barrier(let done):
            done()
            return next()
        }
        let (text, pressReturn, onPosted) = (job.text, job.pressReturn, job.onPosted)

        if text.isEmpty {
            var deleteCount = 0
            if let deleteFirst = job.deleteFirst {
                guard let count = deleteFirst() else {
                    onPosted(-1)
                    job.onSettled(false)
                    next()
                    return
                }
                deleteCount = count
            }
            job.willSend()
            deleteBackward(deleteCount)
            onPosted(nowMs())
            job.onSettled(true)
            next()
            return
        }

        guard let saved = snapshot() else {
            Log.info("paste aborted: could not save the clipboard")
            onPosted(-1)
            job.onSettled(false)
            next()
            return
        }

        // clearContents returns the generation we now own; any other value afterwards is someone else.
        let ourChange = pasteboard.clearContents()
        let item = NSPasteboardItem()
        let promise = PromisedText(text)
        self.promise = promise
        item.setDataProvider(promise, forTypes: [.string])
        item.setData(Data(), forType: Self.transient)
        item.setData(Data(), forType: Self.concealed)
        guard pasteboard.writeObjects([item]), pasteboard.changeCount == ourChange else {
            Log.info("paste aborted: clipboard write failed or was taken over")
            onPosted(-1)
            restore(saved, ifStill: ourChange) { [self] in
                self.promise = nil
                job.onSettled(false)
                next()
            }
            return
        }

        var deleteCount = 0
        if let deleteFirst = job.deleteFirst {
            // Checked after it too: the clipboard may have been taken while it ran.
            guard let count = deleteFirst(), pasteboard.changeCount == ourChange else {
                Log.info("paste aborted: not allowed to delete, or the clipboard was taken")
                onPosted(-1)
                restore(saved, ifStill: ourChange) { [self] in
                    self.promise = nil
                    job.onSettled(false)
                    next()
                }
                return
            }
            deleteCount = count
        }
        job.willSend()
        deleteBackward(deleteCount)

        func abort(_ why: String) {
            Log.info("paste aborted: \(why)")
            onPosted(-1)
            restore(saved, ifStill: ourChange) { [self] in
                self.promise = nil
                job.onSettled(false)
                next()
            }
        }

        func send() {
            let posted = nowMs()
            sendCommandV()
            onPosted(posted)
            if pressReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay) { [self] in sendKey(36) } // kVK_Return
            }

            // Restore once: shortly after the app has read the text, but never before the minimum
            // (and Return, so the clipboard is ours for the whole paste-and-send).
            let minimum = pressReturn ? max(restoreDelay, returnDelay + 0.07) : restoreDelay
            var restored = false
            // Once the app has read, only the read path restores, so its wait is never cut short.
            var read = false
            func finish(_ reason: String) {
                guard !restored else { return }
                restored = true
                if reason != "read" { Log.info("clipboard restored without the app reading it (\(reason))") }
                restore(saved, ifStill: ourChange) { [self] in
                    self.promise = nil
                    job.onSettled(reason == "read")
                    next()
                }
            }
            promise.onRead = {
                read = true
                let elapsed = (nowMs() - posted) / 1000
                if elapsed > 0.3 { Log.info(String(format: "app read the pasted text %.0fms after Cmd+V", elapsed * 1000)) }
                let wait = max(self.afterRead, minimum - elapsed)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { finish("read") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + readTimeout) { if !read { finish("timeout") } }
        }

        // Before pasting a replacement: confirm nothing the user did got in among the Deletes,
        // which would leave the cursor somewhere else.
        guard deleteCount > 0, let afterDelete = job.afterDelete else { return send() }
        afterDelete { [self] ok in
            guard ok else { return abort("input arrived while deleting") }
            guard pasteboard.changeCount == ourChange else { return abort("the clipboard was taken while deleting") }
            send()
        }
    }

    /// Every item with every type, not just strings, so images and files survive.
    /// Returns nil if the item list cannot be read or another app kept changing the clipboard,
    /// so the caller never clears a clipboard it could not save.
    private func snapshot() -> Snapshot? {
        for _ in 0..<3 {
            let before = pasteboard.changeCount
            // nil is a read error; an empty clipboard is [].
            guard let pasteboardItems = pasteboard.pasteboardItems else { continue }
            let items = pasteboardItems.map { item in
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        types[type] = data
                    } else {
                        Log.info("clipboard type unreadable, not restored: \(type.rawValue)")
                    }
                }
                return types
            }
            if pasteboard.changeCount == before { return items }
        }
        return nil
    }

    /// Restores `saved` while the clipboard is still at generation `owned` (ours). If another app
    /// copied in the meantime, theirs wins. A failed write is retried before the queue moves on,
    /// so the next insert never snapshots a half-restored clipboard.
    private func restore(_ saved: Snapshot, ifStill owned: Int, attempt: Int = 1, then done: @escaping () -> Void) {
        guard pasteboard.changeCount == owned else { return done() }
        let generation = pasteboard.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if items.isEmpty || pasteboard.writeObjects(items) { return done() }
        guard attempt < 3 else {
            Log.info("clipboard restore failed; original clipboard lost")
            return done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            restore(saved, ifStill: generation, attempt: attempt + 1, then: done)
        }
    }

    /// Hands the text over only when an app asks for it, and reports that ask (main thread).
    private final class PromisedText: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        var onRead: (() -> Void)?

        init(_ text: String) {
            self.text = text
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            let read = onRead
            onRead = nil
            read?()
        }
    }

    private func deleteBackward(_ count: Int) {
        for _ in 0..<max(count, 0) { sendKey(51) } // kVK_Delete
    }

    private func sendCommandV() {
        sendKey(9, flags: .maskCommand) // kVK_ANSI_V
    }

    /// Flags are set explicitly, so a Shift the user is still holding (the send gesture) does not
    /// turn Return into Shift+Return.
    private func sendKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        pressKey(key, flags)
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
