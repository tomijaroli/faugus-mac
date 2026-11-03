import Darwin
import Foundation

public enum SpawnError: Error, Equatable, CustomStringConvertible {
    case failed(errno: Int32, executable: String)
    public var description: String {
        switch self {
        case let .failed(errorNumber, executable): "posix_spawn(\(executable)) failed: \(String(cString: strerror(errorNumber)))"
        }
    }
}

/// `posix_spawn` wrapper for long-lived children: a new session (so the child survives the
/// parent and can be signalled as a process group), a working directory, `/dev/null` stdin and
/// stdout/stderr redirected to a file or `/dev/null`.
public enum ProcessSpawner {
    public struct Options: Sendable {
        public var workingDirectory: String?
        public var environment: [String: String]
        public var outputFile: String? // appended to; `nil` means /dev/null
        public var newSession: Bool
        public init(
            workingDirectory: String? = nil,
            environment: [String: String],
            outputFile: String? = nil,
            newSession: Bool = true
        ) {
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.outputFile = outputFile
            self.newSession = newSession
        }
    }

    /// Resolves a bare command (no `/`) against `PATH` from the child's environment.
    public static func resolveExecutable(_ name: String, path: String?) -> String? {
        if name.contains("/") {
            return name
        }
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Keys placed last in `envp`. Wine rewrites its own process title over the start of the
    /// argv/environment block (winedevice.exe and friends), which would erase `FAUGUSID`; the
    /// tag must survive so Stop can find every process of a game.
    static let trailingKeys = ["WINEPREFIX", "FAUGUSID"]

    static func orderedEnvironment(_ environment: [String: String]) -> [String] {
        let head = environment.keys.filter { !trailingKeys.contains($0) }.sorted()
        let tail = trailingKeys.filter { environment[$0] != nil }
        return (head + tail).map { "\($0)=\(environment[$0] ?? "")" }
    }

    public static func spawn(commandLine arguments: [String], options: Options) throws -> pid_t {
        guard let first = arguments.first,
              let executablePath = resolveExecutable(first, path: options.environment["PATH"])
        else { throw SpawnError.failed(errno: ENOENT, executable: arguments.first ?? "") }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        if let outputPath = options.outputFile {
            try? FileManager.default.createDirectory(
                atPath: (outputPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            posix_spawn_file_actions_addopen(&fileActions, 1, outputPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        if let workingDirectory = options.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        var flags: Int32 = 0
        if options.newSession {
            flags |= Int32(POSIX_SPAWN_SETSID)
        }
        posix_spawnattr_setflags(&spawnAttributes, Int16(flags))

        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = orderedEnvironment(options.environment).map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid, executablePath, &fileActions, &spawnAttributes, cArguments, cEnvironment
        )
        guard spawnResult == 0 else { throw SpawnError.failed(errno: spawnResult, executable: executablePath) }
        return pid
    }

    /// Blocks (off the cooperative pool) until `pid` exits; returns the exit status, or
    /// `128 + signal` when it was killed by a signal.
    public static func waitForExit(pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 {
                    if errno == EINTR {
                        continue
                    }
                    continuation.resume(returning: -1)
                    return
                }
                if status & 0x7F == 0 {
                    continuation.resume(returning: (status >> 8) & 0xFF)
                } else {
                    continuation.resume(returning: 128 + (status & 0x7F))
                }
            }
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
