import AppKit
import os

/// The app in front, readable from any queue: the recording queue fixes a dictation's text options
/// by it. Kept from activation notifications, which arrive on the main thread.
final class FrontApp {
    private let current = OSAllocatedUnfairLock<(bundleID: String?, name: String?)>(initialState: (nil, nil))
    private var observer: NSObjectProtocol?

    /// Main thread.
    init() {
        set(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.set(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    var bundleID: String? { current.withLock { $0.bundleID } }
    var name: String? { current.withLock { $0.name } }

    /// An app's name for display, from its bundle ID; the ID itself when it is not installed.
    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func set(_ app: NSRunningApplication?) {
        current.withLock { $0 = (app?.bundleIdentifier, app?.localizedName) }
    }
}
