import Darwin
import Foundation

/// APFS clone when the volume allows it, otherwise a regular copy. Prefix trees keep symlinks.
public enum BackupCopy {
    /// Walks `path` like `get_dir_inode_map`: hard-linked files count once.
    public static func directorySize(at path: String) -> Int64 {
        inodeMap(at: path).values.reduce(0, +)
    }

    public static func inodeMap(at path: String, isCancelled: () -> Bool = { false }) -> [String: Int64] {
        let fileManager = FileManager.default
        var sizes: [String: Int64] = [:]
        var uniqueSize: Int64 = 0
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return [:] }
        if !isDirectory.boolValue {
            if let size = linkSize(at: path) {
                return [path: size]
            }
            return [:]
        }
        guard let walker = fileManager.enumerator(atPath: path) else { return [:] }
        for case let relativePath as String in walker {
            if isCancelled() {
                return [:]
            }
            let fullPath = path + "/" + relativePath
            var status = stat()
            guard lstat(fullPath, &status) == 0, (status.st_mode & S_IFMT) != S_IFDIR else { continue }
            if status.st_nlink > 1 {
                sizes["\(status.st_dev)-\(status.st_ino)"] = Int64(status.st_size)
            } else {
                uniqueSize += Int64(status.st_size)
            }
        }
        sizes["unique:\(path)"] = uniqueSize
        return sizes
    }

    /// `get_free_space_bytes`: walk up until a directory exists, then `statvfs`.
    public static func freeSpace(at path: String) -> Int64? {
        var candidate = path
        let fileManager = FileManager.default
        while !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                var stats = statvfs()
                guard statvfs(candidate, &stats) == 0 else { return nil }
                return Int64(stats.f_bavail) * Int64(stats.f_frsize)
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate {
                return nil
            }
            candidate = parent
        }
        return nil
    }

    /// Clone a file or directory onto the same APFS volume; fall back to copy.
    public static func cloneOrCopy(from source: String, to destination: String, preserveSymlinks: Bool = false) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        if preserveSymlinks {
            // Wine prefixes contain dangling dosdevices links; never let copyItem follow them.
            try copyTree(from: source, to: destination, preserveSymlinks: true)
            return
        }
        if clonefile(source, destination, 0) == 0 {
            return
        }
        try copyTree(from: source, to: destination, preserveSymlinks: false)
    }

    public static func copyTree(from source: String, to destination: String, preserveSymlinks: Bool) throws {
        let fileManager = FileManager.default
        var status = stat()
        guard lstat(source, &status) == 0 else { return }
        try fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )

        if (status.st_mode & S_IFMT) == S_IFLNK {
            let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: source)
            if lstat(destination, &status) == 0 {
                try fileManager.removeItem(atPath: destination)
            }
            try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: linkTarget)
            return
        }

        if (status.st_mode & S_IFMT) == S_IFDIR {
            try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(atPath: source)
            for entry in entries {
                try copyTree(
                    from: source + "/" + entry, to: destination + "/" + entry, preserveSymlinks: preserveSymlinks
                )
            }
            return
        }

        if lstat(destination, &status) == 0 {
            try fileManager.removeItem(atPath: destination)
        }
        if clonefile(source, destination, 0) == 0 {
            return
        }
        try fileManager.copyItem(atPath: source, toPath: destination)
    }

    /// Copies only entries whose names are in `includedNames` (`_copy_dir_including`).
    public static func copyMatching(
        from source: String,
        to destination: String,
        includedNames: Set<String>
    ) throws {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: source) else { return }
        try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for name in entries where includedNames.contains(name) {
            try cloneOrCopy(from: source + "/" + name, to: destination + "/" + name)
        }
    }

    public static func replaceDirectory(from source: String, to destination: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try cloneOrCopy(from: source, to: destination, preserveSymlinks: true)
    }

    public static func wipeContents(of directory: String, skipping skippedPath: String?) throws {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        let skipped = skippedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for name in entries {
            let fullPath = directory + "/" + name
            if let skipped, URL(fileURLWithPath: fullPath).standardizedFileURL.path == skipped {
                continue
            }
            try? fileManager.removeItem(atPath: fullPath)
        }
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private static func linkSize(at path: String) -> Int64? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Int64(status.st_size)
    }
}

/// `backup.lock` / `backup.cancel` (`fcntl.flock` in the daemon).
public enum BackupLock {
    public static func isRunning(paths: FaugusPaths) -> Bool {
        let descriptor = open(paths.backupLockFile, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            return errno == EWOULDBLOCK
        }
        _ = flock(descriptor, LOCK_UN)
        return false
    }

    public static func requestCancel(paths: FaugusPaths) {
        try? FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.backupCancelFile, contents: Data())
    }

    public static func throwIfCancelled(paths: FaugusPaths) throws {
        if FileManager.default.fileExists(atPath: paths.backupCancelFile) {
            throw BackupError.cancelled
        }
    }

    public static func withExclusiveLock<Result>(
        paths: FaugusPaths,
        body: () async throws -> Result
    ) async throws -> Result {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: paths.backupCancelFile) {
            try? FileManager.default.removeItem(atPath: paths.backupCancelFile)
        }
        let descriptor = open(paths.backupLockFile, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw BackupError.archiveFailed("Could not open backup lock")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            throw BackupError.alreadyRunning
        }
        defer {
            for stateFile in [paths.backupLockFile, paths.backupCancelFile] {
                try? FileManager.default.removeItem(atPath: stateFile)
            }
            close(descriptor)
        }
        return try await body()
    }
}
