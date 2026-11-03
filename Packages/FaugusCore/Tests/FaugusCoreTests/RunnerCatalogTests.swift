@testable import FaugusCore
import Foundation
import Testing

@Suite("Runner catalog")
struct RunnerCatalogTests {
    private func remote(_ flavor: WineFlavor, _ version: String) -> RemoteRunner {
        RemoteRunner(
            flavor: flavor, version: version, assetName: "wine-\(flavor.rawValue)-\(version)-osx64.tar.xz",
            downloadURL: URL(string: "https://example.com/\(version).tar.xz")!, size: 1, sha256: nil, publishedAt: ""
        )
    }

    private func installed(_ name: String) -> InstalledRunner {
        let (f, v) = RunnerStore.parseName(name)
        return InstalledRunner(
            name: name, directory: "/r/\(name)", wineRoot: "/r/\(name)", flavor: f, version: v, capabilities: .init()
        )
    }

    @Test func listsNewestFirstAndMarksLatestAndInstalled() {
        let feed = [
            remote(.staging, "9.9"),
            remote(.staging, "11.21"),
            remote(.staging, "10.0"),
            remote(.devel, "11.22"),
        ]
        let rows = RunnerCatalog.rows(flavor: .staging, remote: feed, installed: [installed("Wine-Staging-10.0")])
        #expect(rows.map(\.version) == ["11.21", "10.0", "9.9"])
        #expect(rows.map(\.isLatest) == [true, false, false])
        #expect(rows.map(\.isInstalled) == [false, true, false])
        #expect(rows.map(\.directoryName) == ["Wine-Staging-11.21", "Wine-Staging-10.0", "Wine-Staging-9.9"])
    }

    @Test func installedRunnersMissingFromTheFeedStayListed() {
        let feed = [remote(.stable, "11.0")]
        let rows = RunnerCatalog.rows(
            flavor: .stable, remote: feed, installed: [installed("Wine-Stable-8.0"), installed("Wine-Staging-11.21")]
        )
        #expect(rows.map(\.directoryName) == ["Wine-Stable-11.0", "Wine-Stable-8.0"])
        #expect(rows[1].remote == nil && rows[1].isInstalled && !rows[1].isLatest)
    }

    @Test func worksOfflineWithOnlyInstalledRunners() {
        let rows = RunnerCatalog.rows(
            flavor: .staging,
            remote: [],
            installed: [installed("Wine-Staging-10.0"), installed("Wine-Staging-11.21")]
        )
        #expect(rows.map(\.version) == ["11.21", "10.0"])
        // swiftformat:disable:next preferKeyPath (a key path does not compile inside #expect)
        #expect(rows.allSatisfy { $0.isInstalled })
    }

    @Test func duplicateAssetsProduceOneRow() {
        let feed = [remote(.devel, "11.22"), remote(.devel, "11.22")]
        #expect(RunnerCatalog.rows(flavor: .devel, remote: feed, installed: []).count == 1)
    }
}
