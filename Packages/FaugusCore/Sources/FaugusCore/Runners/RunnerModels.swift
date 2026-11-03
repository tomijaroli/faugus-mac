import Foundation

/// The three Gcenx WineHQ build flavours.
public enum WineFlavor: String, CaseIterable, Sendable, Codable {
    case staging, devel, stable

    /// Name used in runner identifiers: `Wine-Staging`, `Wine-Devel`, `Wine-Stable`.
    public var runnerPrefix: String {
        switch self {
        case .staging: return "Wine-Staging"
        case .devel: return "Wine-Devel"
        case .stable: return "Wine-Stable"
        }
    }

    public var latestIdentifier: String { "\(runnerPrefix) Latest" }
}

/// A downloadable runner from the Gcenx release feed.
public struct RemoteRunner: Equatable, Sendable, Identifiable {
    public let flavor: WineFlavor
    public let version: String  // release tag, e.g. `11.21`
    public let assetName: String
    public let downloadURL: URL
    public let size: Int64
    public let sha256: String?
    public let publishedAt: String

    public var id: String { directoryName }
    /// Folder name under `runners/`, also what gets stored in a game's `runner` field.
    public var directoryName: String { "\(flavor.runnerPrefix)-\(version)" }
}

/// Features detected from the files in a Wine tree (plan section 4: detected, never assumed).
public struct RunnerCapabilities: Equatable, Sendable {
    public var vulkan = false
    public var sdl = false
    public var gstreamer = false
    /// Declared by `faugus-runner.json` in the runner directory; never detected.
    public var dxmt = false
    public var d3dmetal = false

    public init(vulkan: Bool = false, sdl: Bool = false, gstreamer: Bool = false, dxmt: Bool = false, d3dmetal: Bool = false) {
        self.vulkan = vulkan; self.sdl = sdl; self.gstreamer = gstreamer
        self.dxmt = dxmt; self.d3dmetal = d3dmetal
    }
}

/// A runner that is present on disk.
public struct InstalledRunner: Equatable, Sendable, Identifiable {
    public let name: String  // directory name, e.g. `Wine-Staging-11.21`
    public let directory: String  // `.../runners/<name>`
    public let wineRoot: String  // directory containing `bin/wine`
    public let flavor: WineFlavor?
    public let version: String?
    public let capabilities: RunnerCapabilities

    public var id: String { name }
    public var wineBinary: String { wineRoot + "/bin/wine" }
    public var wineserverBinary: String { wineRoot + "/bin/wineserver" }
    public var libDirectory: String { wineRoot + "/lib" }
}

public enum RunnerError: Error, Equatable, CustomStringConvertible {
    case notInstalled(String)
    case noWineBinary(String)
    case unsafeArchive(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case extractionFailed(String)
    case noRelease(String)

    public var description: String {
        switch self {
        case .notInstalled(let n): return "Runner \(n) is not installed"
        case .noWineBinary(let d): return "No bin/wine found in \(d)"
        case .unsafeArchive(let m): return "Unsafe archive member: \(m)"
        case .checksumMismatch(let e, let a): return "Checksum mismatch (expected \(e), got \(a))"
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .extractionFailed(let m): return "Extraction failed: \(m)"
        case .noRelease(let m): return "No matching release: \(m)"
        }
    }
}
