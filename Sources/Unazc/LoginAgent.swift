import AppKit
import Darwin

/// Start at login and come back after a crash, through a launchd agent in
/// ~/Library/LaunchAgents. launchd restarts it only when it dies from a crash signal; quitting
/// from the menu or a plain `kill` leaves it stopped.
///
/// Not SMAppService: for an app without a Developer ID, it pins the agent to the exact build that
/// registered it, and launchd refuses every later build (Launch Constraint Violation) even after
/// re-registering. A plain agent naming the executable's path survives rebuilds.
///
/// Exactly one copy runs the app: the one holding an exclusive lock on a file, which the system
/// releases when the process ends however it ends. While the agent is on, that should be the copy
/// launchd started, since only it gets restarted. A copy opened by hand (Finder, `open`) loads the
/// job and quits once launchd reports its copy running; that copy waits briefly for the lock.
/// No notification passes between copies: one delivered late could make the only copy quit.
enum LoginAgent {
    static let label = "io.github.mosle.unazc"
    private static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    private static var domain: String { "gui/\(getuid())" }

    /// Set in the agent's plist, so the process knows launchd started it.
    static var isAgentProcess: Bool { ProcessInfo.processInfo.environment["UNAZC_AGENT"] == "1" }

    /// Whether it starts at next login. Turning it off from launchd's own copy leaves the job
    /// loaded until logout (so a crash before then still restarts it); see `setEnabled`.
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Called before the app is set up. false means this process should exit (successfully, so
    /// launchd does not restart it).
    static func shouldRun() -> Bool {
        if isAgentProcess {
            if crashLooping() {
                Log.info("agent: crashed within \(Int(healthySeconds)) s of starting twice in a row; not restarting it")
                return false
            }
            guard openLock() else {
                resetCrashCount()
                return false
            }
            // The copy that loaded the job is quitting; anything else holding the lock longer
            // (started by hand while the agent was being turned on elsewhere) keeps running.
            let deadline = Date().addingTimeInterval(10)
            while true {
                switch tryLock() {
                case .taken: return true
                case .failed:
                    resetCrashCount()
                    return false
                case .held:
                    guard Date() < deadline else {
                        Log.info("agent: another copy kept running; leaving it")
                        resetCrashCount()
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        resetCrashCount()
        guard openLock() else { return false }
        switch tryLock() {
        case .taken: break
        case .failed: return false
        case .held:
            // A moved app: let the next login start this path even though the old copy runs now.
            if isEnabled, plistProgram() != Bundle.main.executablePath { _ = install() }
            Log.info("already running; not starting a second copy")
            return false
        }
        guard isEnabled else { return true }
        // Opened by hand while the agent is on: have launchd start its copy and leave it the lock.
        // Reloading rather than kickstarting also picks up a new path when the app was moved.
        guard install(), reload() else {
            Log.info("agent: could not start launchd's copy; running here instead")
            return true
        }
        guard handOver() else { return true }
        Log.info("agent: handed over to launchd")
        return false
    }

    /// Turns the agent on or off. Main thread. false (logged) when it could not be done.
    ///
    /// From launchd's own copy, only the plist changes: its job is this very process, so
    /// unloading it would quit the app, and reloading would restart it.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        resetCrashCount()
        if on {
            guard install() else { return false }
            if isAgentProcess { return true }
            // A failed load leaves the plist, so it still starts at the next login.
            guard reload() else { return false }
            // The app (not the CLI) hands over to launchd's copy, which waits for the lock.
            if NSApp?.isRunning == true, handOver() {
                Log.info("agent: handed over to launchd")
                NSApp.terminate(nil)
            }
            return true
        }
        guard remove() else { return false }
        return isAgentProcess || unload()
    }

    /// After loading the job: true once launchd reports its copy running, so this one should quit.
    /// Otherwise (blocked in System Settings, say) the job is unloaded again, so a copy started
    /// late cannot be left waiting behind this one, and this copy carries on; the plist stays for
    /// the next login.
    private static func handOver() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if jobIsRunning() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Log.info("agent: launchd's copy did not start; running here instead")
        _ = unload()
        return false
    }

    /// `kickstart -p` prints the PID of the job's process, starting it if needed: the documented
    /// way to ask, unlike parsing `launchctl print`.
    private static func jobIsRunning() -> Bool {
        let (status, output) = launchctl("kickstart", "-p", "\(domain)/\(label)")
        return status == 0 && Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 > 0 } == true
    }

    private static func install() -> Bool {
        guard let program = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "Program": program,
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["UNAZC_AGENT": "1"],
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            Log.info("agent: cannot write \(plistURL.path): \(error)")
            return false
        }
    }

    private static func remove() -> Bool {
        do {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
            return true
        } catch {
            Log.info("agent: cannot remove \(plistURL.path): \(error)")
            return false
        }
    }

    /// Unloads any loaded copy of the job and loads the plist on disk, which starts it.
    private static func reload() -> Bool {
        guard unload() else { return false }
        // Loading right after unloading can fail while launchd is still tearing the job down.
        for attempt in 0..<5 {
            let status = launchctl("bootstrap", domain, plistURL.path).status
            if status == 0 { return true }
            Log.info("agent: bootstrap exited \(status) (attempt \(attempt + 1))")
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private static func plistProgram() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["Program"] as? String
    }

    /// Unloads the job, stopping launchd's copy if it runs. Not being loaded counts as success.
    private static func unload() -> Bool {
        let status = launchctl("bootout", "\(domain)/\(label)").status
        // 3 and 113: no such job.
        guard status == 0 || status == 3 || status == 113 else {
            Log.info("agent: bootout exited \(status)")
            return false
        }
        return true
    }

    /// Exit status is -1 if launchctl could not run.
    private static func launchctl(_ arguments: String...) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            Log.info("agent: launchctl \(arguments.joined(separator: " ")) failed: \(error)")
            return (-1, "")
        }
    }

    /// The instance lock, held for the life of the process once taken.
    nonisolated(unsafe) private static var lockFD: Int32 = -1
    private static let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).lock")

    private enum LockResult { case taken, held, failed }

    private static func tryLock() -> LockResult {
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return .held }
            guard errno == EINTR else {
                Log.info("cannot lock \(lockURL.path): errno \(errno); not starting, to avoid running twice")
                return .failed
            }
        }
        return .taken
    }

    private static func openLock() -> Bool {
        if lockFD < 0 { lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        if lockFD < 0 { Log.info("cannot open \(lockURL.path): errno \(errno); not starting, to avoid running twice") }
        return lockFD >= 0
    }

    /// Crash-loop guard. Each launchd start records itself until it has run `healthySeconds` or
    /// quits normally; finding the previous record means that run crashed early. The third such
    /// start in a row is refused, since launchd would otherwise retry every 10 s forever.
    private static let startedKey = "agentStartedAt"
    private static let quickCrashesKey = "agentQuickCrashes"
    private static let healthySeconds = 30.0
    nonisolated(unsafe) private static var termSource: DispatchSourceSignal?
    /// Runs on SIGTERM before the agent exits, off the main thread.
    nonisolated(unsafe) static var beforeExit: () -> Void = {}

    private static func crashLooping() -> Bool {
        let defaults = UserDefaults.standard
        let crashes = defaults.object(forKey: startedKey) == nil ? 0 : defaults.integer(forKey: quickCrashesKey) + 1
        guard crashes < 2 else {
            resetCrashCount()
            return true
        }
        defaults.set(crashes, forKey: quickCrashesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: startedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + healthySeconds) { resetCrashCount() }
        // Ending on purpose is not a crash: quitting from the menu or at logout, or a plain kill.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            resetCrashCount()
        }
        // Not on the main queue: the main thread may be blocked waiting for the lock, and
        // launchd's copy must still stop promptly when the agent is unloaded meanwhile.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler {
            resetCrashCount()
            beforeExit()
            Log.flush()
            exit(0)
        }
        term.resume()
        termSource = term
        return false
    }

    private static func resetCrashCount() {
        UserDefaults.standard.removeObject(forKey: startedKey)
        UserDefaults.standard.removeObject(forKey: quickCrashesKey)
        UserDefaults.standard.synchronize()
    }
}
