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
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            // Created on first write, so a run that never logs leaves no folder behind.
            try? fileManager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    public func truncate() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? Data().write(to: URL(fileURLWithPath: path))
    }
}
