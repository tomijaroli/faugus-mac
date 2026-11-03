import Foundation

/// Downloads, verifies, safely extracts and installs a Gcenx Wine runner.
///
/// Invariants (plan section 4): no `LSFileQuarantineEnabled`; `com.apple.quarantine` is removed
/// when present; nothing is re-signed; `bin/wine` is run directly.
public struct RunnerInstaller: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func install(
        _ remote: RemoteRunner,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledRunner {
        let fm = FileManager.default
        try fm.createDirectory(atPath: paths.runnersDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.tempDir, withIntermediateDirectories: true)

        let archive = URL(fileURLWithPath: paths.tempDir).appendingPathComponent(remote.assetName + ".part")
        defer { try? fm.removeItem(at: archive) }

        let downloader = Downloader(destination: archive) { done, total in
            let expected = total > 0 ? total : remote.size
            if expected > 0 {
                progress(min(1, Double(done) / Double(expected)) * 0.7)
            }
        }
        try await downloader.download(remote.downloadURL)

        if let expected = remote.sha256 {
            let actual = try Downloader.sha256(ofFileAt: archive.path)
            guard actual == expected else { throw RunnerError.checksumMismatch(expected: expected, actual: actual) }
        }
        progress(0.75)

        return try await installArchive(
            at: archive.path,
            directoryName: remote.directoryName,
            sourceTag: remote.version
        ) {
            progress(0.75 + 0.25 * $0)
        }
    }

    /// Extracts a local `.tar.xz` into `runners/<directoryName>`.
    public func installArchive(
        at archivePath: String, directoryName: String, sourceTag: String? = nil,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledRunner {
        let fm = FileManager.default
        let staging = paths.runnersDir + "/.staging-" + UUID().uuidString.lowercased()
        let final = paths.runnersDir + "/" + directoryName
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? fm.removeItem(atPath: staging)
            }
        }

        // 1. Reject dangerous member names before anything touches the disk.
        let listing = try await ProcessRunner.run("/usr/bin/tar", ["-tf", archivePath])
        guard listing.succeeded else { throw RunnerError.extractionFailed(listing.stderr) }
        try ArchiveSafety.validate(memberNames: listing.stdout.split(separator: "\n").map(String.init))
        progress(0.4)

        // 2. Extract with bsdtar (secure symlink handling is on by default).
        let extract = try await ProcessRunner.run("/usr/bin/tar", ["-xf", archivePath, "-C", staging])
        guard extract.succeeded else { throw RunnerError.extractionFailed(extract.stderr) }
        progress(0.8)

        // 3. Validate the extracted tree, then make sure it contains a Wine.
        try ArchiveSafety.validateTree(root: staging)
        guard RunnerStore.locateWineRoot(in: staging) != nil else { throw RunnerError.noWineBinary(directoryName) }

        // 4. Quarantine attribute is removed if present; nothing is re-signed.
        _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging])

        let info: JSONValue = [
            "name": .string(directoryName),
            "source": "Gcenx/macOS_Wine_builds",
            "tag": sourceTag.map(JSONValue.string) ?? .null,
        ]
        try JSONFile.save(info, to: staging + "/.faugus-install.json")

        if fm.fileExists(atPath: final) {
            try fm.removeItem(atPath: final)
        }
        try fm.moveItem(atPath: staging, toPath: final)
        succeeded = true
        progress(1)

        guard let runner = RunnerStore(paths: paths).find(name: directoryName) else {
            throw RunnerError.noWineBinary(directoryName)
        }
        return runner
    }

    public func uninstall(name: String) throws {
        guard !name.contains("/"), !name.hasPrefix(".") else { return }
        try FileManager.default.removeItem(atPath: paths.runnersDir + "/" + name)
    }
}
