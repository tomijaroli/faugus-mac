import Foundation

/// Installs, finds and removes shortcut bundles in the two locations. `GameShortcuts` and
/// `FileShortcut` are thin front ends over this; shortcuts are identified by the marker file
/// (`gameid` + `kind`), never by file name.
public struct ShortcutLibrary: Sendable {
    public let paths: FaugusPaths
    /// The Faugus binary every stub `exec`s.
    public let executablePath: String
    /// The bundled Faugus icon, used when a shortcut's own icon is missing or unreadable.
    public let fallbackIconPath: String

    /// Longest file name stem, in UTF-8 bytes, leaving room for ` 99.app` under `NAME_MAX`.
    static let maximumFileNameBytes = 100

    public init(paths: FaugusPaths, executablePath: String, fallbackIconPath: String) {
        self.paths = paths
        self.executablePath = executablePath
        self.fallbackIconPath = fallbackIconPath
    }

    public func directory(for location: ShortcutLocation) -> String {
        switch location {
        case .applicationsMenu: paths.userApplicationsShortcutsDirectory
        case .desktop: paths.desktopDirectory
        }
    }

    // MARK: File names

    /// Strips `/`, `:`, control characters and leading dots, trims whitespace, and falls back to
    /// `fallback` (sanitised the same way) when nothing is left.
    public static func sanitizedFileName(_ title: String, fallback: String) -> String {
        let cleaned = cleanedFileName(title)
        if !cleaned.isEmpty {
            return cleaned
        }
        let cleanedFallback = cleanedFileName(fallback)
        return cleanedFallback.isEmpty ? "Shortcut" : cleanedFallback
    }

    private static func cleanedFileName(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
            where scalar != "/" && scalar != ":" && scalar.properties.generalCategory != .control
        {
            kept.append(scalar)
        }
        var name = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while name.utf8.count > maximumFileNameBytes {
            name.removeLast()
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Scanning

    /// Bundles in `location` whose marker names this shortcut, sorted by file name.
    func bundlePaths(in location: ShortcutLocation, marker: ShortcutMarker) -> [String] {
        let directoryPath = directory(for: location)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath)) ?? []
        return entries
            .filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }
            .sorted()
            .map { directoryPath + "/" + $0 }
            .filter { ShortcutBundle.marker(atBundlePath: $0) == marker }
    }

    public func existingLocations(gameID: String, kind: ShortcutKind) -> Set<ShortcutLocation> {
        let marker = ShortcutMarker(gameID: gameID, kind: kind)
        return Set(ShortcutLocation.allCases.filter { !bundlePaths(in: $0, marker: marker).isEmpty })
    }

    // MARK: Install

    /// Writes the shortcut into each location (replacing the one that already carries the same
    /// marker, renamed if the title changed) and returns the bundle path per location.
    @discardableResult
    public func install(
        marker: ShortcutMarker,
        title: String,
        launch: ShortcutLaunch,
        locations: Set<ShortcutLocation>,
        iconPath: String?
    ) throws -> [ShortcutLocation: String] {
        guard !marker.gameID.isEmpty else { throw ShortcutError.missingIdentifier }
        var installedPaths: [ShortcutLocation: String] = [:]
        for location in ShortcutLocation.allCases where locations.contains(location) {
            try FileManager.default.createDirectory(
                atPath: directory(for: location), withIntermediateDirectories: true
            )
            let previousPaths = bundlePaths(in: location, marker: marker)
            let targetPath = chooseBundlePath(
                in: location, marker: marker, title: title, previousPaths: previousPaths
            )
            try ShortcutBundle.write(
                at: targetPath, title: title, marker: marker, launch: launch,
                iconPath: iconPath, fallbackIconPath: fallbackIconPath
            )
            for previousPath in previousPaths where previousPath != targetPath {
                try ShortcutBundle.remove(bundleAt: previousPath)
            }
            installedPaths[location] = targetPath
        }
        return installedPaths
    }

    /// `<name>.app`, then `<name> 2.app`, `<name> 3.app`, ... The first free name wins; a name
    /// is free when nothing is there or the bundle there already carries this marker. A bundle
    /// of this shortcut that already has the right name (or a numbered variant of it) is kept.
    private func chooseBundlePath(
        in location: ShortcutLocation,
        marker: ShortcutMarker,
        title: String,
        previousPaths: [String]
    ) -> String {
        let directoryPath = directory(for: location)
        let baseName = Self.sanitizedFileName(title, fallback: marker.gameID)
        func candidateName(number: Int) -> String {
            number == 1 ? baseName + ".app" : "\(baseName) \(number).app"
        }
        let maximumNumber = 9999

        let candidateNames = Set((1 ... maximumNumber).map(candidateName(number:)))
        if let keptPath = previousPaths.first(where: {
            candidateNames.contains(($0 as NSString).lastPathComponent)
        }) {
            return keptPath
        }
        for number in 1 ... maximumNumber {
            let candidatePath = directoryPath + "/" + candidateName(number: number)
            if !ShortcutBundle.entryExists(atPath: candidatePath)
                || ShortcutBundle.marker(atBundlePath: candidatePath) == marker
            {
                return candidatePath
            }
        }
        // Ten thousand collisions: fall through to a unique name rather than clobber anything.
        return directoryPath + "/" + baseName + " " + UUID().uuidString.lowercased() + ".app"
    }

    // MARK: Remove

    /// Deletes this shortcut's bundles (marker-gated) and returns the locations that had one.
    @discardableResult
    public func remove(
        marker: ShortcutMarker,
        locations: Set<ShortcutLocation>
    ) throws -> Set<ShortcutLocation> {
        var removedLocations: Set<ShortcutLocation> = []
        for location in ShortcutLocation.allCases where locations.contains(location) {
            for bundlePath in bundlePaths(in: location, marker: marker)
                where try ShortcutBundle.remove(bundleAt: bundlePath)
            {
                removedLocations.insert(location)
            }
        }
        return removedLocations
    }
}
