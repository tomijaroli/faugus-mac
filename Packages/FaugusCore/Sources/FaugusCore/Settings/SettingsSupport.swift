import Foundation

/// `envar.json`: the global environment variables, a JSON list of `KEY=VALUE` lines.
public struct EnvarStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) { self.paths = paths }

    public func load() -> [String] {
        guard case .array(let a) = JSONFile.load(paths.envarFile, default: .array([])) else { return [] }
        return a.compactMap(\.stringValue)
    }

    /// `update_envar_file`: blank lines are dropped.
    public func save(_ lines: [String]) throws {
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        try JSONFile.save(.array(kept.map { .string($0) }), to: paths.envarFile)
    }
}

/// The `rgb(r,g,b)` strings GTK writes into `config.json` (`Gdk.RGBA.to_string`).
public struct ConfigColor: Equatable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int
    public var alpha: Double

    public init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = min(max(alpha, 0), 1)
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, 0), 255) }

    public static let fallback = ConfigColor(red: 61, green: 174, blue: 233)

    /// Accepts `rgb(1,2,3)` and `rgba(1,2,3,0.5)`, with or without spaces.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        let name = s[s.startIndex..<open]
        guard name == "rgb" || name == "rgba" else { return nil }
        let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (name == "rgb" ? 3 : 4) else { return nil }
        guard let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        let a = parts.count == 4 ? Double(parts[3]) : 1
        guard let a else { return nil }
        self.init(red: Int(r.rounded()), green: Int(g.rounded()), blue: Int(b.rounded()), alpha: a)
    }

    /// `Gdk.RGBA.to_string()`: `rgb(...)` when opaque, `rgba(...)` otherwise.
    public var cssString: String {
        if alpha >= 1 { return "rgb(\(red),\(green),\(blue))" }
        return "rgba(\(red),\(green),\(blue),\(Self.trim(alpha)))"
    }

    private static func trim(_ d: Double) -> String {
        var s = String(format: "%.2f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Logs folder helpers behind the Settings "Clear Logs (size)" button.
public enum LogsMaintenance {
    /// `get_dir_size`: `B/KB/MB/GB/TB` with one decimal.
    public static func formatSize(_ bytes: Int64) -> String {
        var total = Double(bytes)
        for unit in ["B", "KB", "MB", "GB"] {
            if total < 1024 { return String(format: "%.1f %@", total, unit) }
            total /= 1024
        }
        return String(format: "%.1f TB", total)
    }

    /// Size of every regular file below `dir`, or `nil` when the directory does not exist.
    public static func size(of dir: String) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
            let walker = fm.enumerator(atPath: dir)
        else { return nil }
        var total: Int64 = 0
        for case let rel as String in walker {
            let attrs = try? fm.attributesOfItem(atPath: dir + "/" + rel)
            if attrs?[.type] as? FileAttributeType == .typeRegular {
                total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// `on_clear_logs_clicked`. Empties the logs folder but keeps the folder itself, so a game
    /// that is running keeps a place to write.
    public static func clear(paths: FaugusPaths) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.logsDir) else { return }
        for name in try fm.contentsOfDirectory(atPath: paths.logsDir) {
            try fm.removeItem(atPath: paths.logsDir + "/" + name)
        }
    }
}
