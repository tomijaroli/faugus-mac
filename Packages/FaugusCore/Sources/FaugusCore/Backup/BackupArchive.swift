import Foundation

/// `/usr/bin/tar` (and zip via `/usr/bin/unzip` / `ditto`) with `ArchiveSafety` on the member list.
public enum BackupArchive {
    public static func createArchive(from stagingDirectory: String, to archivePath: String) async throws {
        let result = try await ProcessRunner.run(
            "/usr/bin/tar",
            ["-cf", archivePath, "-C", stagingDirectory, "."]
        )
        guard result.succeeded else {
            throw BackupError.archiveFailed(result.stderr.isEmpty ? "tar exited \(result.status)" : result.stderr)
        }
    }

    public static func extract(archivePath: String, to destinationDirectory: String) async throws {
        try FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        let names = try await memberNames(of: archivePath)
        do {
            try ArchiveSafety.validate(memberNames: names)
        } catch let RunnerError.unsafeArchive(member) {
            throw BackupError.unsafeArchive(member)
        }
        if archivePath.lowercased().hasSuffix(".zip") {
            let result = try await ProcessRunner.run(
                "/usr/bin/ditto",
                ["-x", "-k", archivePath, destinationDirectory]
            )
            guard result.succeeded else {
                throw BackupError.archiveFailed(result.stderr.isEmpty ? "ditto exited \(result.status)" : result.stderr)
            }
        } else {
            let result = try await ProcessRunner.run(
                "/usr/bin/tar",
                ["-xf", archivePath, "-C", destinationDirectory]
            )
            guard result.succeeded else {
                throw BackupError.archiveFailed(result.stderr.isEmpty ? "tar exited \(result.status)" : result.stderr)
            }
        }
        // Prefixes keep absolute dosdevices links (z: → /). Member names were already checked;
        // do not run ArchiveSafety.validateTree here.
    }

    public static func memberNames(of archivePath: String) async throws -> [String] {
        if archivePath.lowercased().hasSuffix(".zip") {
            let result = try await ProcessRunner.run("/usr/bin/unzip", ["-Z1", archivePath])
            guard result.succeeded else {
                throw BackupError.invalidArchive
            }
            return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        }
        let result = try await ProcessRunner.run("/usr/bin/tar", ["-tf", archivePath])
        guard result.succeeded else {
            throw BackupError.invalidArchive
        }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func isFaugusBackup(stagingDirectory: String) -> Bool {
        let markerPath = stagingDirectory + "/" + BackupFormat.markerName
        guard let data = FileManager.default.contents(atPath: markerPath),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == BackupFormat.markerText
    }
}
