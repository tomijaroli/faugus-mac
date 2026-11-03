import Darwin
import Foundation

/// Finds processes by environment variable. Wine on macOS has no Proton-style container, so the
/// `FAUGUSID=<gameid>` variable that every game process inherits is how stray children are
/// found (replaces upstream's `/proc/<pid>/environ` scan, plan section 3 "Stop/kill").
public enum ProcessScanner {
    public static func allPIDs() -> [pid_t] {
        var sysctlName: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&sysctlName, UInt32(sysctlName.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls; ask for some slack.
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&sysctlName, UInt32(sysctlName.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        return buffer.withUnsafeBytes { rawBytes in
            (0 ..< count).compactMap { entryIndex in
                let processInfo = rawBytes.load(fromByteOffset: entryIndex * stride, as: kinfo_proc.self)
                return processInfo.kp_proc.p_pid > 0 ? processInfo.kp_proc.p_pid : nil
            }
        }
    }

    /// When `pid` was started (replaces psutil's `create_time`).
    public static func startDate(of pid: pid_t) -> Date? {
        var sysctlName: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&sysctlName, UInt32(sysctlName.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        let startTime = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000)
    }

    /// The environment of `pid`, if readable (same user, not hardened-protected).
    public static func environment(of pid: pid_t) -> [String: String]? {
        var sysctlName: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&sysctlName, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&sysctlName, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        buffer = Array(buffer.prefix(size))

        // Layout: argc (Int32), exec path, NULs, argv[0..argc), NULs, env strings.
        var argumentCount: Int32 = 0
        memcpy(&argumentCount, buffer, MemoryLayout<Int32>.size)
        var position = MemoryLayout<Int32>.size
        while position < buffer.count, buffer[position] != 0 {
            position += 1
        } // exec path
        while position < buffer.count, buffer[position] == 0 {
            position += 1
        } // padding
        var seen: Int32 = 0
        while seen < argumentCount, position < buffer.count { // skip argv
            while position < buffer.count, buffer[position] != 0 {
                position += 1
            }
            position += 1
            seen += 1
        }
        var variables: [String: String] = [:]
        while position < buffer.count {
            var entryEnd = position
            while entryEnd < buffer.count, buffer[entryEnd] != 0 {
                entryEnd += 1
            }
            // Wine rewrites its process title over the start of the argv/env block, which can
            // leave empty strings in the middle: skip them rather than stopping.
            if entryEnd == position {
                position += 1
                continue
            }
            let entry = String(decoding: buffer[position ..< entryEnd], as: UTF8.self)
            if let equalsIndex = entry.firstIndex(of: "=") {
                variables[String(entry[..<equalsIndex])] = String(entry[entry.index(after: equalsIndex)...])
            }
            position = entryEnd + 1
        }
        return variables
    }

    /// Processes whose environment has `key == value` (never includes the caller).
    public static func pids(withEnvironment key: String, equalTo value: String) -> [pid_t] {
        let currentProcessID = getpid()
        return allPIDs().filter { $0 != currentProcessID && environment(of: $0)?[key] == value }
    }

    /// `kill_by_faugusid`: SIGKILL everything tagged with this game id.
    @discardableResult
    public static func killByFaugusID(_ id: String, signal signalNumber: Int32 = SIGKILL) -> [pid_t] {
        let victims = pids(withEnvironment: "FAUGUSID", equalTo: id)
        for victim in victims {
            kill(victim, signalNumber)
        }
        return victims
    }
}
