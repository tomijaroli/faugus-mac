@testable import FaugusCore
import Foundation

enum TestSupport {
    static func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    /// Repository root, derived from this file's location.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FaugusCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FaugusCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    static var upstreamLanguagesDirectory: URL {
        repoRoot.appendingPathComponent("upstream/languages")
    }

    static func makeTemporaryHome() throws -> FaugusPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("faugus-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FaugusPaths(home: directory.path)
    }

    static func cleanup(_ paths: FaugusPaths) {
        try? FileManager.default.removeItem(atPath: paths.home)
    }

    static func install(fixture: String, at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try fixtureData(fixture).write(to: URL(fileURLWithPath: path))
    }
}
