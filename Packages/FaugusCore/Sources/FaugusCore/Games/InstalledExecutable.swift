import Foundation

/// Finds the executable an installer just set up, from the `.lnk` shortcuts it leaves in the
/// prefix (upstream `detect_installed_executable` and helpers in `utils.py`).
public enum InstalledExecutable {
    // MARK: Listing

    /// Every `.lnk` under the prefix's user profiles and ProgramData.
    public static func shortcuts(inPrefix prefix: String) -> Set<String> {
        var found: Set<String> = []
        let fileManager = FileManager.default
        for root in [prefix + "/drive_c/users", prefix + "/drive_c/ProgramData"] {
            guard let walker = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in walker where relativePath.lowercased().hasSuffix(".lnk") {
                found.insert(root + "/" + relativePath)
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
        let reader = Reader(data)
        guard reader.count >= 76, reader.bytes(0, 4) == [0x4C, 0, 0, 0] else { return nil }
        guard let flags = reader.readUInt32(20) else { return nil }
        let hasIDList: UInt32 = 0x01
        let hasLinkInfo: UInt32 = 0x02

        var offset = 76
        if flags & hasIDList != 0 {
            guard let size = reader.readUInt16(offset) else { return nil }
            offset += 2 + Int(size)
        }
        guard flags & hasLinkInfo != 0, offset + 8 <= reader.count else { return nil }

        let start = offset
        guard let headerSize = reader.readUInt32(start + 4),
              let infoFlags = reader.readUInt32(start + 8) else { return nil }
        let volumeIDAndLocalBasePath: UInt32 = 0x01
        guard infoFlags & volumeIDAndLocalBasePath != 0 else { return nil }

        guard let localBase = reader.readUInt32(start + 16) else { return nil }
        var localBaseUnicode: UInt32 = 0
        if headerSize >= 0x24, start + 32 <= reader.count {
            localBaseUnicode = reader.readUInt32(start + 28) ?? 0
        }

        if localBaseUnicode != 0 {
            let stringStart = start + Int(localBaseUnicode)
            guard stringStart <= reader.count,
                  let stringEnd = reader.utf16TerminatorOffset(stringStart) else { return nil }
            return String(data: data[stringStart ..< stringEnd], encoding: .utf16LittleEndian)
        }
        if localBase != 0 {
            let stringStart = start + Int(localBase)
            guard stringStart <= reader.count,
                  let stringEnd = reader.byteTerminatorOffset(stringStart) else { return nil }
            // cp1252 maps bytes 0x80-0x9F differently from Latin-1; windowsCP1252 handles it.
            return String(data: data[stringStart ..< stringEnd], encoding: .windowsCP1252)
        }
        return nil
    }

    private struct Reader {
        let data: Data
        init(_ data: Data) {
            self.data = data
        }

        var count: Int {
            data.count
        }

        func bytes(_ offset: Int, _ length: Int) -> [UInt8]? {
            guard offset >= 0, length >= 0, offset + length <= count else { return nil }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + length])
        }

        func readUInt16(_ offset: Int) -> UInt16? {
            guard let byteValues = bytes(offset, 2) else { return nil }
            return UInt16(byteValues[0]) | UInt16(byteValues[1]) << 8
        }

        func readUInt32(_ offset: Int) -> UInt32? {
            guard let byteValues = bytes(offset, 4) else { return nil }
            return UInt32(byteValues[0]) | UInt32(byteValues[1]) << 8 | UInt32(byteValues[2]) << 16 |
                UInt32(byteValues[3]) << 24
        }

        func byteTerminatorOffset(_ startOffset: Int) -> Int? {
            var offset = startOffset
            while offset < count {
                if data[data.startIndex + offset] == 0 {
                    return offset
                }
                offset += 1
            }
            return nil
        }

        func utf16TerminatorOffset(_ startOffset: Int) -> Int? {
            var offset = startOffset
            while offset + 1 < count {
                if data[data.startIndex + offset] == 0, data[data.startIndex + offset + 1] == 0 {
                    return offset
                }
                offset += 2
            }
            return nil
        }
    }

    // MARK: Path mapping

    /// `C:\Games\Foo\foo.exe` to a path inside the prefix (`drive_c`, or a `dosdevices` drive).
    public static func prefixPath(forWindowsPath windowsPath: String, prefix: String) -> String? {
        let trimmed = windowsPath.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let characters = Array(trimmed)
        guard characters.count >= 2, characters[1] == ":" else { return nil }
        let drive = String(characters[0]).lowercased()
        var rest = String(characters.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        while rest.hasPrefix("/") {
            rest.removeFirst()
        }
        if drive == "c" {
            return prefix + "/drive_c/" + rest
        }
        let device = prefix + "/dosdevices/" + drive + ":"
        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: device)) != nil {
            let resolvedPath = URL(fileURLWithPath: device).resolvingSymlinksInPath().path
            return (resolvedPath as NSString).appendingPathComponent(rest)
        }
        return nil
    }

    /// The file at `path`, or a file in the same folder whose name differs only by case
    /// (Windows paths do not care about case, APFS volumes may).
    public static func resolveCaseInsensitive(_ path: String) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            // On a case-insensitive volume the lookup succeeds with any spelling; report the real one.
            let url = URL(fileURLWithPath: path)
            return (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? path
        }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent.lowercased()
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        for entry in entries where entry.lowercased() == name {
            let fullPath = directory + "/" + entry
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue {
                return fullPath
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
        for shortcutPath in newShortcuts.sorted() {
            byName[(shortcutPath as NSString).lastPathComponent.lowercased(), default: []].append(shortcutPath)
        }
        var results: [Shortcut] = []
        for (_, paths) in byName.sorted(by: { $0.key < $1.key }) {
            let file = (paths[0] as NSString).lastPathComponent
            let name = ((file as NSString).deletingPathExtension).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || isUtilityShortcut(file, name) {
                continue
            }
            var target: String?
            for linkPath in paths {
                guard let windowsPath = targetPath(ofLink: linkPath),
                      let candidate = prefixPath(forWindowsPath: windowsPath, prefix: prefix),
                      let resolved = resolveCaseInsensitive(candidate), resolved.lowercased().hasSuffix(".exe")
                else { continue }
                target = resolved
                break
            }
            guard let target else { continue }
            let directories = paths.map { ($0 as NSString).deletingLastPathComponent }
            results.append(
                Shortcut(
                    name: name, target: target,
                    onDesktop: directories.contains { $0.contains("/Desktop") },
                    onStartMenu: directories.contains { $0.contains("/Start Menu") },
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
