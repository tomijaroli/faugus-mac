import Foundation

/// One line of the Runner Manager: a downloadable release, an installed runner, or both.
public struct RunnerRow: Identifiable, Equatable, Sendable {
    public let flavor: WineFlavor
    public let version: String
    /// Folder name under `runners/`, also what a game's `runner` field stores.
    public let directoryName: String
    public let remote: RemoteRunner?
    public let isInstalled: Bool
    /// The newest release of its flavor: what "<Flavor> Latest" resolves to once installed.
    public let isLatest: Bool

    public var id: String {
        directoryName
    }
}

public enum RunnerCatalog {
    /// Rows for one flavor tab, newest first. Installed runners that the feed no longer lists
    /// (older releases, manual installs named like a release) stay visible so they can be removed.
    public static func rows(flavor: WineFlavor, remote: [RemoteRunner], installed: [InstalledRunner]) -> [RunnerRow] {
        let releases = remote.filter { $0.flavor == flavor }
            .sorted { VersionKey($0.version) > VersionKey($1.version) }
        let installedNames = Set(installed.map(\.name))
        var rows: [RunnerRow] = []
        var seen: Set<String> = []
        for (index, release) in releases.enumerated() where seen.insert(release.directoryName).inserted {
            rows.append(
                RunnerRow(
                    flavor: flavor, version: release.version, directoryName: release.directoryName, remote: release,
                    isInstalled: installedNames.contains(release.directoryName), isLatest: index == 0
                )
            )
        }
        let extras = installed.filter { $0.flavor == flavor && !seen.contains($0.name) }
            .sorted { VersionKey($0.version ?? $0.name) > VersionKey($1.version ?? $1.name) }
        for extra in extras {
            rows.append(
                RunnerRow(
                    flavor: flavor, version: extra.version ?? extra.name, directoryName: extra.name, remote: nil,
                    isInstalled: true, isLatest: releases.isEmpty && rows.isEmpty && extras.first == extra
                )
            )
        }
        return rows
    }
}
