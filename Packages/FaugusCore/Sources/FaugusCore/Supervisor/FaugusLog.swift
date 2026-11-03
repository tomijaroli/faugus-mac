import Foundation

/// Appends timestamped lines to `~/Library/Logs/Faugus/<id>/faugus.log`.
public final class FaugusLog: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func write(_ message: String) {
        let line = "[\(PlaytimeStore.isoNow())] \(message)\n"
        append(line)
    }

    public func writeSection(_ title: String, _ lines: [String]) {
        append("\n=== \(title) ===\n" + lines.joined(separator: "\n") + "\n\n")
    }

    private func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // Created on first write, so a run that never logs leaves no folder behind.
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    }

    public func truncate() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data().write(to: URL(fileURLWithPath: path))
    }
}
