import Darwin
import Foundation

/// What is needed to recognise a running game by its process (Discord's detectable-application
/// matching): the process name, `argv[0]` and where it runs from.
public struct ProcessCandidate: Equatable, Sendable {
    public var name: String
    /// `argv[0]`. Wine rewrites it to a Windows path such as `C:\windows\system32\game.exe`.
    public var firstArgument: String
    public var workingDirectory: String?

    public init(name: String, firstArgument: String, workingDirectory: String? = nil) {
        self.name = name
        self.firstArgument = firstArgument
        self.workingDirectory = workingDirectory
    }
}

/// The `KERN_PROCARGS2` block of one process.
public struct ProcessArguments: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

/// Reads a process's name, executable path, `argv` and working directory (psutil's `name`,
/// `exe`, `cmdline` and `cwd` on Linux). Only processes of the same user are readable.
public enum ProcessInspector {
    /// Layout of the block: `argc` (Int32), executable path, NUL padding, `argc` argument strings,
    /// then the environment strings. Wine rewrites its process title over the start of the
    /// argument/environment block, which can leave empty strings in the environment part;
    /// those are skipped like `ProcessScanner.environment(of:)` does.
    static func parseProcessArguments(_ buffer: [UInt8]) -> ProcessArguments? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        var argumentCount: Int32 = 0
        memcpy(&argumentCount, buffer, MemoryLayout<Int32>.size)
        var position = MemoryLayout<Int32>.size

        let pathStart = position
        while position < buffer.count, buffer[position] != 0 {
            position += 1
        }
        let executablePath = String(decoding: buffer[pathStart ..< position], as: UTF8.self)
        while position < buffer.count, buffer[position] == 0 {
            position += 1
        }

        var arguments: [String] = []
        while Int32(arguments.count) < argumentCount, position < buffer.count {
            let argumentStart = position
            while position < buffer.count, buffer[position] != 0 {
                position += 1
            }
            arguments.append(String(decoding: buffer[argumentStart ..< position], as: UTF8.self))
            position += 1
        }

        var environment: [String: String] = [:]
        while position < buffer.count {
            var entryEnd = position
            while entryEnd < buffer.count, buffer[entryEnd] != 0 {
                entryEnd += 1
            }
            if entryEnd == position {
                position += 1
                continue
            }
            let entry = String(decoding: buffer[position ..< entryEnd], as: UTF8.self)
            if let equalsIndex = entry.firstIndex(of: "=") {
                environment[String(entry[..<equalsIndex])] = String(entry[entry.index(after: equalsIndex)...])
            }
            position = entryEnd + 1
        }
        return ProcessArguments(executablePath: executablePath, arguments: arguments, environment: environment)
    }

    public static func arguments(of pid: pid_t) -> ProcessArguments? {
        var sysctlName: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&sysctlName, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&sysctlName, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// The kernel's short name of the process (`p_comm`).
    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return decodeCString(buffer)
    }

    public static func workingDirectory(of pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, expectedSize) == expectedSize else { return nil }
        let path = withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { rawPath in
            String(decoding: rawPath.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// One `ProcessCandidate` per process (other than the caller) whose environment has
    /// `key == value`. The tag is read with `ProcessScanner` (the same parser Stop uses);
    /// `KERN_PROCARGS2` argv is then taken from `arguments(of:)` for Discord matching.
    public static func candidates(withEnvironment key: String, equalTo value: String) -> [ProcessCandidate] {
        var candidates: [ProcessCandidate] = []
        for pid in ProcessScanner.pids(withEnvironment: key, equalTo: value) {
            let details = arguments(of: pid)
            let fallbackName = details.map { ($0.executablePath as NSString).lastPathComponent } ?? ""
            candidates.append(ProcessCandidate(
                name: name(of: pid) ?? fallbackName,
                firstArgument: details?.arguments.first ?? "",
                workingDirectory: workingDirectory(of: pid)
            ))
        }
        return candidates
    }

    private static func decodeCString(_ characters: [CChar]) -> String {
        let bytes = characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
