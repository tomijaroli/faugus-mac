import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool {
        status == 0
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case launchFailed(String)
}

/// Runs a short-lived helper process and captures its output. Game processes are not run
/// through here; they are spawned detached (see `ProcessSpawner`).
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let out = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = out
        process.standardError = standardErrorPipe
        process.standardInput = FileHandle.nullDevice

        // Buffered, so the exit status can never be missed whichever side is first.
        let (exits, exitSink) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finishedProcess in
            exitSink.yield(finishedProcess.terminationStatus)
            exitSink.finish()
        }

        do { try process.run() } catch {
            throw ProcessRunnerError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        // Drain both pipes while the child runs, otherwise a chatty child blocks on a full pipe.
        async let outData = readAll(out.fileHandleForReading)
        async let errData = readAll(standardErrorPipe.fileHandleForReading)
        var status: Int32 = -1
        for await exitStatus in exits {
            status = exitStatus
        }

        return await ProcessResult(
            status: status,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}
