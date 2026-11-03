import Darwin
import Foundation

/// Finds processes by environment variable. Wine on macOS has no Proton-style container, so the
/// `FAUGUSID=<gameid>` variable that every game process inherits is how stray children are
/// found (replaces upstream's `/proc/<pid>/environ` scan, plan section 3 "Stop/kill").
public enum ProcessScanner {
    public static func allPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls; ask for some slack.
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        return buffer.withUnsafeBytes { raw in
            (0 ..< count).compactMap { i in
                let p = raw.load(fromByteOffset: i * stride, as: kinfo_proc.self)
                return p.kp_proc.p_pid > 0 ? p.kp_proc.p_pid : nil
            }
        }
    }

    /// When `pid` was started (replaces psutil's `create_time`).
    public static func startDate(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid
        else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    /// The environment of `pid`, if readable (same user, not hardened-protected).
    public static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        buffer = Array(buffer.prefix(size))

        // Layout: argc (Int32), exec path, NULs, argv[0..argc), NULs, env strings.
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        var i = MemoryLayout<Int32>.size
        while i < buffer.count, buffer[i] != 0 {
            i += 1
        } // exec path
        while i < buffer.count, buffer[i] == 0 {
            i += 1
        } // padding
        var seen: Int32 = 0
        while seen < argc, i < buffer.count { // skip argv
            while i < buffer.count, buffer[i] != 0 {
                i += 1
            }
            i += 1
            seen += 1
        }
        var env: [String: String] = [:]
        while i < buffer.count {
            var j = i
            while j < buffer.count, buffer[j] != 0 {
                j += 1
            }
            // Wine rewrites its process title over the start of the argv/env block, which can
            // leave empty strings in the middle: skip them rather than stopping.
            if j == i {
                i += 1
                continue
            }
            let entry = String(decoding: buffer[i ..< j], as: UTF8.self)
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            i = j + 1
        }
        return env
    }

    /// Processes whose environment has `key == value` (never includes the caller).
    public static func pids(withEnvironment key: String, equalTo value: String) -> [pid_t] {
        let me = getpid()
        return allPIDs().filter { $0 != me && environment(of: $0)?[key] == value }
    }

    /// `kill_by_faugusid`: SIGKILL everything tagged with this game id.
    @discardableResult
    public static func killByFaugusID(_ id: String, signal sig: Int32 = SIGKILL) -> [pid_t] {
        let victims = pids(withEnvironment: "FAUGUSID", equalTo: id)
        for p in victims {
            kill(p, sig)
        }
        return victims
    }
}
