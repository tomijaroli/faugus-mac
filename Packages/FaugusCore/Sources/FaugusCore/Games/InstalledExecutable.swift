import Foundation

/// Finds the executable an installer just set up, from the `.lnk` shortcuts it leaves in the
/// prefix (upstream `detect_installed_executable` and helpers in `utils.py`).
public enum InstalledExecutable {
    // MARK: Listing

    /// Every `.lnk` under the prefix's user profiles and ProgramData.
    public static func shortcuts(inPrefix prefix: String) -> Set<String> {
        var found: Set<String> = []
        let fm = FileManager.default
        for root in [prefix + "/drive_c/users", prefix + "/drive_c/ProgramData"] {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in walker where rel.lowercased().hasSuffix(".lnk") {
                found.insert(root + "/" + rel)
            }
        }
        return found
    }

    // MARK: Parsing

    /// The local base path stored in a shell link (`LinkInfo`), or nil when it has none.
    /// Bounds-checked: every read goes through `Reader`.
    public static func targetPath(ofLink path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return targetPath(inLink: data)
    }

    public static func targetPath(inLink data: Data) -> String? {
        let r = Reader(data)
        guard r.count >= 76, r.bytes(0, 4) == [0x4C, 0, 0, 0] else { return nil }
        guard let flags = r.u32(20) else { return nil }
        let hasIDList: UInt32 = 0x01
        let hasLinkInfo: UInt32 = 0x02

        var offset = 76
        if flags & hasIDList != 0 {
            guard let size = r.u16(offset) else { return nil }
            offset += 2 + Int(size)
        }
        guard flags & hasLinkInfo != 0, offset + 8 <= r.count else { return nil }

        let start = offset
        guard let headerSize = r.u32(start + 4), let infoFlags = r.u32(start + 8) else { return nil }
        let volumeIDAndLocalBasePath: UInt32 = 0x01
        guard infoFlags & volumeIDAndLocalBasePath != 0 else { return nil }

        guard let localBase = r.u32(start + 16) else { return nil }
        var localBaseUnicode: UInt32 = 0
        if headerSize >= 0x24, start + 32 <= r.count {
            localBaseUnicode = r.u32(start + 28) ?? 0
        }

        if localBaseUnicode != 0 {
            let from = start + Int(localBaseUnicode)
            guard from <= r.count, let end = r.utf16TerminatorOffset(from) else { return nil }
            return String(data: data[from ..< end], encoding: .utf16LittleEndian)
        }
        if localBase != 0 {
            let from = start + Int(localBase)
            guard from <= r.count, let end = r.byteTerminatorOffset(from) else { return nil }
            // cp1252 maps bytes 0x80-0x9F differently from Latin-1; windowsCP1252 handles it.
            return String(data: data[from ..< end], encoding: .windowsCP1252)
        }
        return nil
    }

    private struct Reader {
        let data: Data
        init(_ d: Data) {
            data = d
        }

        var count: Int {
            data.count
        }

        func bytes(_ at: Int, _ n: Int) -> [UInt8]? {
            guard at >= 0, n >= 0, at + n <= count else { return nil }
            return Array(data[data.startIndex + at ..< data.startIndex + at + n])
        }

        func u16(_ at: Int) -> UInt16? {
            guard let b = bytes(at, 2) else { return nil }
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }

        func u32(_ at: Int) -> UInt32? {
            guard let b = bytes(at, 4) else { return nil }
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        func byteTerminatorOffset(_ from: Int) -> Int? {
            var i = from
            while i < count {
                if data[data.startIndex + i] == 0 {
                    return i
                }
                i += 1
            }
            return nil
        }

        func utf16TerminatorOffset(_ from: Int) -> Int? {
            var i = from
            while i + 1 < count {
                if data[data.startIndex + i] == 0, data[data.startIndex + i + 1] == 0 {
                    return i
                }
                i += 2
            }
            return nil
        }
    }

    // MARK: Path mapping

    /// `C:\Games\Foo\foo.exe` to a path inside the prefix (`drive_c`, or a `dosdevices` drive).
    public static func prefixPath(forWindowsPath win: String, prefix: String) -> String? {
        let trimmed = win.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let chars = Array(trimmed)
        guard chars.count >= 2, chars[1] == ":" else { return nil }
        let drive = String(chars[0]).lowercased()
        var rest = String(chars.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        while rest.hasPrefix("/") {
            rest.removeFirst()
        }
        if drive == "c" {
            return prefix + "/drive_c/" + rest
        }
        let device = prefix + "/dosdevices/" + drive + ":"
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: device)) != nil {
            let real = URL(fileURLWithPath: device).resolvingSymlinksInPath().path
            return (real as NSString).appendingPathComponent(rest)
        }
        return nil
    }

    /// The file at `path`, or a file in the same folder whose name differs only by case
    /// (Windows paths do not care about case, APFS volumes may).
    public static func resolveCaseInsensitive(_ path: String) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            // On a case-insensitive volume the lookup succeeds with any spelling; report the real one.
            let url = URL(fileURLWithPath: path)
            return (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? path
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent.lowercased()
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries where entry.lowercased() == name {
            let full = dir + "/" + entry
            if fm.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                return full
            }
        }
        return nil
    }

    private static let utilityKeywords = ["uninstall", "setup", "config", "readme"]

    public static func isUtilityShortcut(_ names: String...) -> Bool {
        let combined = names.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        return utilityKeywords.contains { combined.contains($0) }
    }

    // MARK: Detection

    public struct Shortcut: Equatable, Sendable {
        public var name: String
        public var target: String
        public var onDesktop: Bool
        public var onStartMenu: Bool
        public var shortcutPath: String
    }

    /// New shortcuts that point at an `.exe` inside the prefix, utilities (uninstallers, setup,
    /// config tools, readmes) excluded. Shortcuts with the same file name are grouped.
    public static func resolveNew(_ newShortcuts: Set<String>, prefix: String) -> [Shortcut] {
        var byName: [String: [String]] = [:]
        for p in newShortcuts.sorted() {
            byName[(p as NSString).lastPathComponent.lowercased(), default: []].append(p)
        }
        var results: [Shortcut] = []
        for (_, paths) in byName.sorted(by: { $0.key < $1.key }) {
            let file = (paths[0] as NSString).lastPathComponent
            let name = ((file as NSString).deletingPathExtension).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || isUtilityShortcut(file, name) {
                continue
            }
            var target: String?
            for lnk in paths {
                guard let win = targetPath(ofLink: lnk),
                      let candidate = prefixPath(forWindowsPath: win, prefix: prefix),
                      let resolved = resolveCaseInsensitive(candidate), resolved.lowercased().hasSuffix(".exe")
                else { continue }
                target = resolved
                break
            }
            guard let target else { continue }
            let dirs = paths.map { ($0 as NSString).deletingLastPathComponent }
            results.append(
                Shortcut(
                    name: name, target: target,
                    onDesktop: dirs.contains { $0.contains("/Desktop") },
                    onStartMenu: dirs.contains { $0.contains("/Start Menu") },
                    shortcutPath: paths[0]
                )
            )
        }
        return results
    }

    /// Upstream picks the alphabetically first name.
    public static func best(_ resolved: [Shortcut]) -> Shortcut? {
        resolved.min { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// `detect_installed_executable`: the executable of the best new shortcut since `existing`.
    public static func detect(prefix: String, existing: Set<String>) -> String? {
        best(resolveNew(shortcuts(inPrefix: prefix).subtracting(existing), prefix: prefix))?.target
    }
}
