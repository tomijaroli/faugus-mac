import Foundation

public struct WinetricksVerb: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let summary: String
    public let category: String
    public var id: String { name }
}

public struct WinetricksCategory: Equatable, Sendable, Identifiable {
    public let name: String
    public let verbs: [WinetricksVerb]
    public var id: String { name }
}

public enum Winetricks {
    /// Parses `winetricks list-all` (`===== dlls =====` headings, then `verb  description`).
    /// Anything else the script prints (`Executing ...`, warnings) is ignored.
    /// The `prefix` heading only lists meta-verbs that install a whole category; it is left out.
    public static let hiddenCategories: Set<String> = ["prefix"]

    public static func parseList(_ output: String) -> [WinetricksCategory] {
        var order: [String] = []
        var verbs: [String: [WinetricksVerb]] = [:]
        var current: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("===== "), line.hasSuffix(" =====") {
                let name = String(line.dropFirst(6).dropLast(6))
                current = name
                if verbs[name] == nil { order.append(name); verbs[name] = [] }
                continue
            }
            guard let category = current, let first = line.first, !first.isWhitespace else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let name = parts.first, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "=" }),
                !name.hasSuffix("=")
            else { continue }
            let summary = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            verbs[category, default: []].append(WinetricksVerb(name: String(name), summary: summary, category: category))
        }
        return order.compactMap { name in
            guard !hiddenCategories.contains(name), let list = verbs[name], !list.isEmpty else { return nil }
            return WinetricksCategory(name: name, verbs: list)
        }
    }

    /// Verbs winetricks recorded in the prefix (`winetricks.log`, one verb per line).
    public static func installedVerbs(prefix: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: prefix + "/winetricks.log", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// `PATH` entries a Finder-launched app lacks but winetricks needs (`cabextract`, `7z`...).
    public static let extraPathDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public static func cabextractPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = (extraPathDirectories + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        return ProcessSpawner.resolveExecutable("cabextract", path: path)
    }

    /// Hint shown when `cabextract` is missing: many verbs (vcrun, dotnet, d3dx9...) need it.
    public static let cabextractInstallHint = "brew install cabextract"
}

/// A winetricks invocation: argv, environment and the log file the output goes to.
public struct WinetricksInvocation: Sendable {
    public var argv: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var logFile: String

    /// Unattended install of `verbs` (`winetricks -q <verbs>`).
    public static func install(
        verbs: [String], prefix: String, runner: InstalledRunner, paths: FaugusPaths, logName: String = "winetricks",
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> WinetricksInvocation {
        make(
            arguments: ["-q"] + verbs, prefix: prefix, runner: runner, paths: paths, logName: logName, base: base)
    }

    /// `winetricks list-all`: needs no prefix, only a Wine on `PATH`.
    public static func listAll(
        prefix: String, runner: InstalledRunner, paths: FaugusPaths,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> WinetricksInvocation {
        make(arguments: ["list-all"], prefix: prefix, runner: runner, paths: paths, logName: "winetricks-list", base: base)
    }

    static func make(
        arguments: [String], prefix: String, runner: InstalledRunner, paths: FaugusPaths, logName: String = "winetricks",
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> WinetricksInvocation {
        let component = WinetricksComponent(paths: paths)
        var env = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: base)
        let basePath = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([runner.wineRoot + "/bin"] + Winetricks.extraPathDirectories + [basePath]).joined(separator: ":")
        env["W_CACHE"] = component.cacheDirectory
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        let argv = ["/bin/sh", component.scriptPath] + arguments
        return WinetricksInvocation(
            argv: argv, environment: env, workingDirectory: prefix,
            logFile: paths.gameLogsDir(gameID: logName) + "/winetricks.log")
    }
}

/// Reads what a child process appended to its log file, line by line.
public final class LogTail: @unchecked Sendable {
    private let path: String
    private var offset: UInt64 = 0
    private var pending = Data()

    public init(path: String, fromStart: Bool = true) {
        self.path = path
        if !fromStart, let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64 {
            offset = size
        }
    }

    /// New complete lines since the last call (a trailing partial line waits for its newline).
    /// `\r` ends a line too, because curl and winetricks redraw progress with it.
    public func poll(flush: Bool = false) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        pending.append(data)
        var lines: [String] = []
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...i)
            if !line.isEmpty { lines.append(line) }
        }
        if flush, !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return lines
    }
}
