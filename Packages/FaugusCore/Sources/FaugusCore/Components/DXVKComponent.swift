import Foundation

/// DXVK-macOS (Gcenx repack), downloaded at runtime and never bundled (plan section 4).
///
/// The non-builtin repack has only `d3d10core.dll` and `d3d11.dll` for x32 and x64: no dxgi,
/// no d3d9. It is copied into the prefix's `system32` / `syswow64`.
public struct DXVKComponent: Sendable {
    public static let tag = "v1.10.3-20230507-repack"
    public static let assetName = "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
    public static let archiveRoot = "dxvk-macOS-async-v1.10.3-20230507-repack"
    public static let downloadURL = URL(
        string: "https://github.com/Gcenx/DXVK-macOS/releases/download/\(tag)/\(assetName)"
    )!
    /// GitHub exposes no digest for this asset, so it is pinned here.
    public static let sha256 = "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"
    public static let dllNames = ["d3d10core.dll", "d3d11.dll"]

    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public var installDirectory: String {
        paths.dxvkMacOSDir + "/" + DXVKComponent.tag
    }

    public var x64Directory: String {
        installDirectory + "/x64"
    }

    public var x32Directory: String {
        installDirectory + "/x32"
    }

    public var isInstalled: Bool {
        let fileManager = FileManager.default
        return DXVKComponent.dllNames.allSatisfy {
            let hasX64 = fileManager.fileExists(atPath: x64Directory + "/" + $0)
            let hasX32 = fileManager.fileExists(atPath: x32Directory + "/" + $0)
            return hasX64 && hasX32
        }
    }

    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if isInstalled {
            return
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: paths.tempDirectory, withIntermediateDirectories: true)
        let archive = URL(fileURLWithPath: paths.tempDirectory)
            .appendingPathComponent(DXVKComponent.assetName + ".part")
        defer { try? fileManager.removeItem(at: archive) }

        let downloader = Downloader(destination: archive) { done, total in
            if total > 0 {
                progress(min(1, Double(done) / Double(total)) * 0.8)
            }
        }
        try await downloader.download(DXVKComponent.downloadURL)
        try installArchive(at: archive.path, expectedSHA256: DXVKComponent.sha256)
        progress(1)
    }

    /// Verifies, safely extracts and installs a local archive.
    public func installArchive(at path: String, expectedSHA256: String?) throws {
        let fileManager = FileManager.default
        if let expected = expectedSHA256 {
            let actual = try Downloader.sha256(ofFileAt: path)
            guard actual == expected else { throw RunnerError.checksumMismatch(expected: expected, actual: actual) }
        }
        let staging = paths.dxvkMacOSDir + "/.staging-" + UUID().uuidString.lowercased()
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: staging) }

        let list = try Self.runSync("/usr/bin/tar", ["-tf", path])
        try ArchiveSafety.validate(memberNames: list.split(separator: "\n").map(String.init))
        _ = try Self.runSync("/usr/bin/tar", ["-xf", path, "-C", staging])
        try ArchiveSafety.validateTree(root: staging)

        let extractedRoot = staging + "/" + DXVKComponent.archiveRoot
        for architecture in ["x32", "x64"] {
            for dllName in DXVKComponent.dllNames {
                let dllPath = "\(extractedRoot)/\(architecture)/\(dllName)"
                if !fileManager.fileExists(atPath: dllPath) {
                    throw RunnerError.extractionFailed("missing \(architecture)/\(dllName)")
                }
            }
        }
        if fileManager.fileExists(atPath: installDirectory) {
            try fileManager.removeItem(atPath: installDirectory)
        }
        try fileManager.createDirectory(atPath: paths.dxvkMacOSDir, withIntermediateDirectories: true)
        try fileManager.moveItem(atPath: extractedRoot, toPath: installDirectory)
    }

    private static func runSync(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        try process.run()
        let data = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunnerError.extractionFailed(String(decoding: errorData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
