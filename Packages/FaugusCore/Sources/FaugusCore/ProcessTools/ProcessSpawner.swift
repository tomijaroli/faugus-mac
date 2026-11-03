import Darwin
import Foundation

public enum SpawnError: Error, Equatable, CustomStringConvertible {
    case failed(errno: Int32, executable: String)
    public var description: String {
        switch self {
        case let .failed(e, exe): "posix_spawn(\(exe)) failed: \(String(cString: strerror(e)))"
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
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = String(dir) + "/" + name
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

    static func orderedEnvironment(_ env: [String: String]) -> [String] {
        let head = env.keys.filter { !trailingKeys.contains($0) }.sorted()
        let tail = trailingKeys.filter { env[$0] != nil }
        return (head + tail).map { "\($0)=\(env[$0] ?? "")" }
    }

    public static func spawn(argv: [String], options: Options) throws -> pid_t {
        guard let first = argv.first,
              let exe = resolveExecutable(first, path: options.environment["PATH"])
        else { throw SpawnError.failed(errno: ENOENT, executable: argv.first ?? "") }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        if let out = options.outputFile {
            try? FileManager.default.createDirectory(
                atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            posix_spawn_file_actions_addopen(&fileActions, 1, out, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        if let cwd = options.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var flags: Int32 = 0
        if options.newSession {
            flags |= Int32(POSIX_SPAWN_SETSID)
        }
        posix_spawnattr_setflags(&attr, Int16(flags))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = orderedEnvironment(options.environment).map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fileActions, &attr, cArgs, cEnv)
        guard rc == 0 else { throw SpawnError.failed(errno: rc, executable: exe) }
        return pid
    }

    /// Blocks (off the cooperative pool) until `pid` exits; returns the exit status, or
    /// `128 + signal` when it was killed by a signal.
    public static func waitForExit(pid: pid_t) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 {
                    if errno == EINTR {
                        continue
                    }
                    cont.resume(returning: -1)
                    return
                }
                if status & 0x7F == 0 {
                    cont.resume(returning: (status >> 8) & 0xFF)
                } else {
                    cont.resume(returning: 128 + (status & 0x7F))
                }
            }
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
