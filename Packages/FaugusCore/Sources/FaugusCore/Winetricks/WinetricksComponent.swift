import Foundation

/// The winetricks script, downloaded at runtime and pinned by version and SHA-256 (plan section 4).
/// It is a plain shell script that runs under macOS' `/bin/sh`; it is never modified.
public struct WinetricksComponent: Sendable {
    public static let version = "20260125"
    public static let downloadURL = URL(
        string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(version)/src/winetricks"
    )!
    public static let sha256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"

    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public var directory: String {
        paths.winetricksDirectory + "/" + Self.version
    }

    public var scriptPath: String {
        directory + "/winetricks"
    }

    /// Downloads (`W_CACHE`): shared by every prefix, so a verb is fetched once.
    public var cacheDirectory: String {
        paths.winetricksDirectory + "/cache"
    }

    public var isInstalled: Bool {
        FileManager.default.isReadableFile(atPath: scriptPath)
    }

    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if isInstalled {
            return
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: paths.tempDirectory, withIntermediateDirectories: true)
        let part = URL(fileURLWithPath: paths.tempDirectory).appendingPathComponent("winetricks-\(Self.version).part")
        defer { try? fm.removeItem(at: part) }
        let downloader = Downloader(destination: part) { done, total in
            if total > 0 {
                progress(min(1, Double(done) / Double(total)))
            }
        }
        try await downloader.download(Self.downloadURL)
        try installScript(at: part.path, expectedSHA256: Self.sha256)
        progress(1)
    }

    /// Verifies a local copy and installs it atomically.
    public func installScript(at path: String, expectedSHA256: String?) throws {
        let fm = FileManager.default
        if let expected = expectedSHA256 {
            let actual = try Downloader.sha256(ofFileAt: path)
            guard actual == expected else { throw RunnerError.checksumMismatch(expected: expected, actual: actual) }
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let staged = directory + "/.winetricks-" + UUID().uuidString.lowercased()
        try fm.copyItem(atPath: path, toPath: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        // A downloaded file is never quarantined by URLSession, but a manually supplied one may be.
        removexattr(staged, "com.apple.quarantine", 0)
        if fm.fileExists(atPath: scriptPath) {
            try fm.removeItem(atPath: scriptPath)
        }
        try fm.moveItem(atPath: staged, toPath: scriptPath)
    }
}
