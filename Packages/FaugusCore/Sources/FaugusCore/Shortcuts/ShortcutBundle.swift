import Foundation

/// Writes and removes the stub `.app` that stands in for upstream's `.desktop` file.
///
/// ```
/// Name.app/Contents/Info.plist
/// Name.app/Contents/MacOS/launch                      /bin/sh script, so no code signature is needed
/// Name.app/Contents/Resources/AppIcon.icns
/// Name.app/Contents/Resources/faugus-shortcut.json    {"gameid": ..., "kind": "game"|"file"}
/// ```
///
/// Bundles are built in a hidden sibling directory and swapped into place, so a half-written
/// bundle is never visible. Nothing here follows a symlink when it replaces or deletes, and only
/// bundles that carry the marker file are ever replaced or deleted.
public enum ShortcutBundle {
    public static let bundleIdentifierPrefix = "me.tomijaroli.faugus-mac.shortcut."
    public static let markerRelativePath = "Contents/Resources/faugus-shortcut.json"
    public static let launchScriptRelativePath = "Contents/MacOS/launch"
    public static let iconRelativePath = "Contents/Resources/AppIcon.icns"
    public static let infoPropertyListRelativePath = "Contents/Info.plist"

    // MARK: Writing

    /// Creates (or atomically replaces) the bundle at `bundlePath`.
    ///
    /// - Throws: `foreignBundleInTheWay` when something without the Faugus marker already
    ///   occupies `bundlePath`; `iconUnavailable` when neither icon decodes.
    public static func write( // swiftlint:disable:this function_parameter_count
        at bundlePath: String,
        title: String,
        marker: ShortcutMarker,
        launch: ShortcutLaunch,
        iconPath: String?,
        fallbackIconPath: String
    ) throws {
        guard let iconData = ShortcutIconBuilder.icnsData(iconPath: iconPath, fallbackIconPath: fallbackIconPath)
        else { throw ShortcutError.iconUnavailable }

        let fileManager = FileManager.default
        let parentDirectory = (bundlePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)

        let stagingPath = parentDirectory + "/.faugus-" + UUID().uuidString.lowercased() + ".tmp"
        do {
            try buildContents(
                at: stagingPath, title: title, marker: marker, launch: launch, iconData: iconData
            )
            try moveIntoPlace(stagingPath: stagingPath, bundlePath: bundlePath)
        } catch {
            try? fileManager.removeItem(atPath: stagingPath)
            throw error
        }
    }

    private static func buildContents(
        at stagingPath: String,
        title: String,
        marker: ShortcutMarker,
        launch: ShortcutLaunch,
        iconData: Data
    ) throws {
        let fileManager = FileManager.default
        for relativeDirectory in ["Contents/MacOS", "Contents/Resources"] {
            try fileManager.createDirectory(
                atPath: stagingPath + "/" + relativeDirectory, withIntermediateDirectories: true
            )
        }
        try infoPropertyList(title: title, gameID: marker.gameID)
            .write(to: URL(fileURLWithPath: stagingPath + "/" + infoPropertyListRelativePath))
        try iconData.write(to: URL(fileURLWithPath: stagingPath + "/" + iconRelativePath))
        try JSONWriter.serialize(markerJSON(marker)).write(
            to: URL(fileURLWithPath: stagingPath + "/" + markerRelativePath)
        )

        let scriptPath = stagingPath + "/" + launchScriptRelativePath
        try Data(launchScript(for: launch).utf8).write(to: URL(fileURLWithPath: scriptPath))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    // MARK: Contents

    /// `CFBundleIdentifier` suffix: ASCII letters, digits, `-` and `.` only.
    public static func sanitizedIdentifier(_ gameID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        let sanitized = String(gameID.map { allowed.contains($0) ? $0 : "-" })
        return sanitized.isEmpty ? "game" : sanitized
    }

    public static func infoPropertyList(title: String, gameID: String) throws -> Data {
        let dictionary: [String: Any] = [
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": bundleIdentifierPrefix + sanitizedIdentifier(gameID),
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "NSHighResolutionCapable": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// The `/bin/sh` stub. Every word goes through `ShellWords.quote`, so titles, paths and
    /// arguments with spaces, quotes or `$` reach Faugus untouched.
    public static func launchScript(for launch: ShortcutLaunch) -> String {
        var lines = ["#!/bin/sh"]
        if let workingDirectory = launch.workingDirectory, !workingDirectory.isEmpty {
            lines.append("if [ -d \(ShellWords.quote(workingDirectory)) ]; then")
            lines.append("    cd -- \(ShellWords.quote(workingDirectory)) || exit 1")
            lines.append("fi")
        }
        for variable in launch.environment where ShellWords.isIdentifier(variable.name) {
            lines.append("export \(variable.name)=\(ShellWords.quote(variable.value))")
        }
        lines.append("exec " + ShellWords.join([launch.executablePath] + launch.arguments))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markerJSON(_ marker: ShortcutMarker) -> JSONValue {
        .object(["gameid": .string(marker.gameID), "kind": .string(marker.kind.rawValue)])
    }

    // MARK: Marker and ownership

    /// The marker of the bundle at `bundlePath`, or `nil` when it is not a Faugus shortcut.
    /// Every path component down to the marker must be a real directory or file (no symlinks).
    public static func marker(atBundlePath bundlePath: String) -> ShortcutMarker? {
        guard entryType(atPath: bundlePath) == S_IFDIR,
              entryType(atPath: bundlePath + "/Contents") == S_IFDIR,
              entryType(atPath: bundlePath + "/Contents/Resources") == S_IFDIR,
              entryType(atPath: bundlePath + "/" + markerRelativePath) == S_IFREG,
              let data = FileManager.default.contents(atPath: bundlePath + "/" + markerRelativePath),
              data.count < 65536,
              let object = (try? JSONParser.parse(data))?.objectValue,
              let gameID = object["gameid"]?.stringValue,
              let kind = object["kind"]?.stringValue.flatMap(ShortcutKind.init(rawValue:))
        else { return nil }
        return ShortcutMarker(gameID: gameID, kind: kind)
    }

    /// Whether anything (file, folder or dangling symlink) exists at `path`, without following links.
    public static func entryExists(atPath path: String) -> Bool {
        entryType(atPath: path) != nil
    }

    // MARK: Removing

    /// Deletes the bundle when it carries the marker file. Returns whether it was deleted.
    @discardableResult
    public static func remove(bundleAt bundlePath: String) throws -> Bool {
        guard marker(atBundlePath: bundlePath) != nil else { return false }
        try FileManager.default.removeItem(atPath: bundlePath)
        return true
    }

    // MARK: Atomic replace

    private static func entryType(atPath path: String) -> mode_t? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_mode & S_IFMT
    }

    private static func moveIntoPlace(stagingPath: String, bundlePath: String) throws {
        func failure(_ operation: String) -> ShortcutError {
            .writeFailed(path: bundlePath, reason: "\(operation): \(String(cString: strerror(errno)))")
        }

        if entryType(atPath: bundlePath) == nil {
            // RENAME_EXCL: never clobber something that appeared since the check.
            guard renamex_np(stagingPath, bundlePath, UInt32(RENAME_EXCL)) == 0 else { throw failure("rename") }
            return
        }
        guard marker(atBundlePath: bundlePath) != nil else {
            throw ShortcutError.foreignBundleInTheWay(bundlePath)
        }
        if renamex_np(stagingPath, bundlePath, UInt32(RENAME_SWAP)) == 0 {
            // The staging path now holds the previous bundle.
            try? FileManager.default.removeItem(atPath: stagingPath)
            return
        }
        // Volumes without RENAME_SWAP: move the old bundle aside, then the new one in.
        let backupPath = stagingPath + ".old"
        guard rename(bundlePath, backupPath) == 0 else { throw failure("rename") }
        guard rename(stagingPath, bundlePath) == 0 else {
            let renameFailure = failure("rename")
            _ = rename(backupPath, bundlePath)
            throw renameFailure
        }
        try? FileManager.default.removeItem(atPath: backupPath)
    }
}
