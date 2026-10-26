import AppKit
import Testing
@testable import Unazc

/// PasteInserter against a private clipboard, with keys recorded instead of sent. A Cmd+V is
/// answered the way an app does, by reading the clipboard shortly after.
@MainActor @Suite(.serialized) struct PasteInserterTests {
    private let pasteboard = NSPasteboard(name: .init("unazc-test-\(UUID().uuidString)"))
    private let commandV: CGKeyCode = 9
    private let delete: CGKeyCode = 51
    private final class Keys { var pressed: [CGKeyCode] = [] }
    private let keys = Keys()

    private func makeInserter() -> PasteInserter {
        pasteboard.clearContents()
        pasteboard.setString("元のクリップボード", forType: .string)
        let (keys, pasteboard, commandV) = (keys, pasteboard, commandV)
        return PasteInserter(pasteboard: pasteboard) { key, _ in
            keys.pressed.append(key)
            if key == commandV { DispatchQueue.main.async { _ = pasteboard.string(forType: .string) } }
        }
    }

    private func wait(_ seconds: Double = 3, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func pasteIsReadAndTheClipboardComesBack() async {
        let inserter = makeInserter()
        var settled: Bool?
        inserter.insert("こんにちは", onSettled: { settled = $0 })
        await wait { settled != nil }
        #expect(settled == true)
        #expect(keys.pressed == [commandV])
        #expect(pasteboard.string(forType: .string) == "元のクリップボード")
    }

    @Test func refusedDeletionSendsNothing() async {
        let inserter = makeInserter()
        var settled: Bool?
        inserter.insert("新しい", deleteFirst: { nil }, onSettled: { settled = $0 })
        await wait { settled != nil }
        #expect(settled == false)
        #expect(keys.pressed.isEmpty)
        #expect(pasteboard.string(forType: .string) == "元のクリップボード")
    }

    @Test func inputDuringTheDeletesStopsTheReplacement() async {
        let inserter = makeInserter()
        var settled: Bool?
        inserter.insert("新しい", deleteFirst: { 3 }, afterDelete: { done in done(false) }, onSettled: { settled = $0 })
        await wait { settled != nil }
        #expect(settled == false)
        #expect(keys.pressed == [delete, delete, delete])
        #expect(pasteboard.string(forType: .string) == "元のクリップボード")
    }

    @Test func nothingElseRunsWhileTheCheckIsPending() async {
        let inserter = makeInserter()
        var pending: ((Bool) -> Void)?
        var settled: [String] = []
        inserter.insert("一つ目", deleteFirst: { 2 }, afterDelete: { pending = $0 }, onSettled: { _ in settled.append("一つ目") })
        inserter.insert("二つ目", onSettled: { _ in settled.append("二つ目") })
        await wait(0.3) { false }
        #expect(keys.pressed == [delete, delete])
        pending?(true)
        await wait { settled.count == 2 }
        #expect(settled == ["一つ目", "二つ目"])
        #expect(keys.pressed == [delete, delete, commandV, commandV])
        #expect(pasteboard.string(forType: .string) == "元のクリップボード")
    }

    @Test func clipboardTakenDuringTheCheckStopsThePaste() async {
        let inserter = makeInserter()
        var settled: Bool?
        inserter.insert("新しい", deleteFirst: { 1 }, afterDelete: { [pasteboard] done in
            pasteboard.clearContents()
            pasteboard.setString("ほかのアプリ", forType: .string)
            done(true)
        }, onSettled: { settled = $0 })
        await wait { settled != nil }
        #expect(settled == false)
        #expect(keys.pressed == [delete])
        #expect(pasteboard.string(forType: .string) == "ほかのアプリ")
    }
}
