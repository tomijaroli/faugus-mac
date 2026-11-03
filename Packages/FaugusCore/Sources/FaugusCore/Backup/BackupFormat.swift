import Foundation

/// Layout of a Faugus backup archive (`backup.py` / `backup_daemon.py`).
public enum BackupFormat {
    public static let markerName = ".faugus_marker"
    public static let markerText = "faugus-launcher-backup"
    public static let manifestName = "manifest.json"
    public static let manifestVersion = 2

    /// Settings trees inside the archive, matching `faugus_roots()`.
    public static let settingsRoots = ["config", "data", "state"]

    /// `format_size` in `backup_daemon.py`: integer bytes, otherwise two decimal places.
    public static func formatSize(_ bytes: Int64) -> String {
        var size = Double(max(0, bytes))
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if size < 1024 || unit == "TB" {
                if unit == "B" {
                    return "\(Int(size)) \(unit)"
                }
                return String(format: "%.2f \(unit)", size)
            }
            size /= 1024
        }
        return "\(bytes) B"
    }

    /// `backup_filename`: `faugus-launcher-YYYY-mm-dd_HH-MM-SS.tar`.
    public static func archiveFileName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "faugus-launcher-\(formatter.string(from: now)).tar"
    }

    /// Last-backup stamp written to `backup-last-date`: `YYYY-mm-dd HH:MM`.
    public static func lastBackupStamp(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: now)
    }

    /// `unique_backup_path`: first free `name.tar`, then `name-2.tar`, `name-3.tar`, ...
    public static func uniqueArchivePath(
        in destinationDirectory: String,
        fileName: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let chosenName = fileName ?? archiveFileName(now: now, timeZone: timeZone)
        let stem = (chosenName as NSString).deletingPathExtension
        let pathExtension = (chosenName as NSString).pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var candidate = destinationDirectory + "/" + chosenName
        var number = 2
        while fileExists(candidate) {
            candidate = destinationDirectory + "/" + "\(stem)-\(number)\(suffix)"
            number += 1
        }
        return candidate
    }
}

public struct BackupManifestEntry: Equatable, Sendable {
    public var gameID: String
    public var title: String
    public var originalPath: String

    public init(gameID: String, title: String, originalPath: String = "") {
        self.gameID = gameID
        self.title = title
        self.originalPath = originalPath
    }
}

public struct BackupManifestShortcut: Equatable, Sendable {
    public var gameID: String
    public var title: String
    public var originalPaths: [String]

    public init(gameID: String, title: String, originalPaths: [String]) {
        self.gameID = gameID
        self.title = title
        self.originalPaths = originalPaths
    }
}

/// `manifest.json` version 2.
public struct BackupManifest: Equatable, Sendable {
    public var version: Int
    public var games: [BackupManifestEntry]
    public var prefixes: [BackupManifestEntry]
    public var shortcuts: [BackupManifestShortcut]
    public var protons: [BackupManifestEntry]

    public init(
        version: Int = BackupFormat.manifestVersion,
        games: [BackupManifestEntry] = [],
        prefixes: [BackupManifestEntry] = [],
        shortcuts: [BackupManifestShortcut] = [],
        protons: [BackupManifestEntry] = []
    ) {
        self.version = version
        self.games = games
        self.prefixes = prefixes
        self.shortcuts = shortcuts
        self.protons = protons
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        version = Int(object["version"]?.intValue ?? Int64(BackupFormat.manifestVersion))
        games = BackupManifest.parseEntries(object["games"])
        prefixes = BackupManifest.parseEntries(object["prefixes"])
        protons = BackupManifest.parseEntries(object["protons"])
        shortcuts = (object["shortcuts"]?.arrayValue ?? []).compactMap { entry in
            guard let item = entry.objectValue, let gameID = item["gameid"]?.stringValue else { return nil }
            let paths = item["original_paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return BackupManifestShortcut(
                gameID: gameID, title: item["title"]?.stringValue ?? gameID, originalPaths: paths
            )
        }
    }

    public func json() -> JSONValue {
        var object = JSONObject()
        object["version"] = .int(Int64(version))
        object["games"] = .array(games.map { $0.json(includePath: false) })
        object["prefixes"] = .array(prefixes.map { $0.json(includePath: true) })
        object["shortcuts"] = .array(shortcuts.map(\.json))
        object["protons"] = .array(protons.map { $0.json(includePath: true) })
        return .object(object)
    }

    private static func parseEntries(_ value: JSONValue?) -> [BackupManifestEntry] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let item = entry.objectValue, let gameID = item["gameid"]?.stringValue else { return nil }
            return BackupManifestEntry(
                gameID: gameID,
                title: item["title"]?.stringValue ?? gameID,
                originalPath: item["original_path"]?.stringValue ?? ""
            )
        }
    }
}

extension BackupManifestEntry {
    fileprivate func json(includePath: Bool) -> JSONValue {
        var object = JSONObject()
        object["gameid"] = .string(gameID)
        object["title"] = .string(title)
        if includePath {
            object["original_path"] = .string(originalPath)
        }
        return .object(object)
    }
}

extension BackupManifestShortcut {
    fileprivate var json: JSONValue {
        var object = JSONObject()
        object["gameid"] = .string(gameID)
        object["title"] = .string(title)
        object["original_paths"] = .array(originalPaths.map { .string($0) })
        return .object(object)
    }
}

public enum BackupError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case notEnoughSpace(needed: Int64, available: Int64)
    case invalidArchive
    case unsafeArchive(String)
    case archiveFailed(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .cancelled: "Backup cancelled"
        case let .notEnoughSpace(needed, available):
            "not enough disk space (\(BackupFormat.formatSize(needed)) needed, \(BackupFormat.formatSize(available)) available)"
        case .invalidArchive: "This is not a valid Faugus backup file."
        case let .unsafeArchive(member): "Unsafe archive member: \(member)"
        case let .archiveFailed(message): message
        case .alreadyRunning: "A backup is already running"
        }
    }
}
