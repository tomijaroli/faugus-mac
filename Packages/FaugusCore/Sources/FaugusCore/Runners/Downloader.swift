import CryptoKit
import Foundation

/// Downloads one file to disk with progress reporting.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    public init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        self.destination = destination
        self.progress = progress
    }

    public func download(_ url: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var req = URLRequest(url: url)
        req.setValue("Faugus-for-Mac", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                setContinuation(cont)
                session.downloadTask(with: req).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// Lock helpers are synchronous: NSLock cannot be used directly from async contexts.
    private func setContinuation(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = cont
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    private func setMoveError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        moveError = error
    }

    private func currentMoveError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return moveError
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            setMoveError(RunnerError.downloadFailed("HTTP \(http.statusCode)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setMoveError(error)
        }
    }

    public func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = takeContinuation()
        if let error {
            cont?.resume(throwing: RunnerError.downloadFailed(error.localizedDescription))
        } else if let moved = currentMoveError() {
            cont?.resume(throwing: moved)
        } else {
            cont?.resume()
        }
    }

    // MARK: Checksums

    public static func sha256(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw RunnerError.downloadFailed("cannot read \(path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
