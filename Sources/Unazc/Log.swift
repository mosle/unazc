import Foundation

/// Writes to stderr and ~/Library/Logs/Unazc/unazc.log so timings can be compared across builds.
enum Log {
    private static let queue = DispatchQueue(label: "unazc.log")
    private static let handle: FileHandle? = {
        // Tests stay on stderr so the real log only holds real use; detected by the runner's process
        // name, since the CLI's arguments can be any file name.
        guard !["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName) else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Unazc")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("unazc.log")
        // Append mode: two copies can be writing at once while one hands over to the other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }

    /// Waits for queued lines to be written, before an exit().
    static func flush() {
        queue.sync {}
    }
}

/// Monotonic milliseconds for latency measurement.
@inline(__always) func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}
