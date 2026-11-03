import Foundation

/// `environmentVariable.json`: the global environment variables, a JSON list of `KEY=VALUE` lines.
public struct EnvironmentVariableStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func load() -> [String] {
        guard case let .array(lines) = JSONFile.load(paths.environmentVariablesFile, default: .array([])) else {
            return []
        }
        return lines.compactMap(\.stringValue)
    }

    /// `update_envar_file`: blank lines are dropped.
    public func save(_ lines: [String]) throws {
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        try JSONFile.save(.array(kept.map { .string($0) }), to: paths.environmentVariablesFile)
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

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }

    public static let fallback = ConfigColor(red: 61, green: 174, blue: 233)

    /// Accepts `rgb(1,2,3)` and `rgba(1,2,3,0.5)`, with or without spaces.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else {
            return nil
        }
        let name = trimmed[trimmed.startIndex ..< open]
        guard name == "rgb" || name == "rgba" else { return nil }
        let parts = trimmed[trimmed.index(after: open) ..< close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (name == "rgb" ? 3 : 4) else { return nil }
        guard let redValue = Double(parts[0]),
              let greenValue = Double(parts[1]),
              let blueValue = Double(parts[2])
        else { return nil }
        let parsedAlpha = parts.count == 4 ? Double(parts[3]) : 1
        guard let parsedAlpha else { return nil }
        self.init(
            red: Int(redValue.rounded()),
            green: Int(greenValue.rounded()),
            blue: Int(blueValue.rounded()),
            alpha: parsedAlpha
        )
    }

    /// `Gdk.RGBA.to_string()`: `rgb(...)` when opaque, `rgba(...)` otherwise.
    public var cssString: String {
        if alpha >= 1 {
            return "rgb(\(red),\(green),\(blue))"
        }
        return "rgba(\(red),\(green),\(blue),\(Self.trim(alpha)))"
    }

    private static func trim(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}

/// Logs folder helpers behind the Settings "Clear Logs (size)" button.
public enum LogsMaintenance {
    /// `get_dir_size`: `B/KB/MB/GB/TB` with one decimal.
    public static func formatSize(_ bytes: Int64) -> String {
        var total = Double(bytes)
        for unit in ["B", "KB", "MB", "GB"] {
            if total < 1024 {
                return String(format: "%.1f %@", total, unit)
            }
            total /= 1024
        }
        return String(format: "%.1f TB", total)
    }

    /// Size of every regular file below `directory`, or `nil` when the directory does not exist.
    public static func size(of directory: String) -> Int64? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let walker = fileManager.enumerator(atPath: directory)
        else { return nil }
        var total: Int64 = 0
        for case let relativePath as String in walker {
            let attributes = try? fileManager.attributesOfItem(atPath: directory + "/" + relativePath)
            if attributes?[.type] as? FileAttributeType == .typeRegular {
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// `on_clear_logs_clicked`. Empties the logs folder but keeps the folder itself, so a game
    /// that is running keeps a place to write.
    public static func clear(paths: FaugusPaths) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.logsDirectory) else { return }
        for name in try fileManager.contentsOfDirectory(atPath: paths.logsDirectory) {
            try fileManager.removeItem(atPath: paths.logsDirectory + "/" + name)
        }
    }
}
