@testable import FaugusCore
import Foundation
import Testing

@Suite("Settings support", .serialized)
struct SettingsSupportTests {
    @Test func environmentVariablesFileDropsBlankLinesAndKeepsOrder() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = EnvironmentVariableStore(paths: paths)
        #expect(store.load().isEmpty)
        try store.save(["A=1", "", "  ", "B=two words"])
        #expect(store.load() == ["A=1", "B=two words"])
        // The launch plan reads the same file.
        #expect(JSONFile.load(paths.environmentVariablesFile) == .array(["A=1", "B=two words"]))
    }

    @Test func colorsParseAndFormatLikeGdk() {
        #expect(ConfigColor("rgb(61,174,233)") == ConfigColor(red: 61, green: 174, blue: 233))
        #expect(ConfigColor("rgb( 1, 2 ,3 )") == ConfigColor(red: 1, green: 2, blue: 3))
        #expect(ConfigColor("\"rgb(9,8,7)\"") == ConfigColor(red: 9, green: 8, blue: 7))
        #expect(ConfigColor("rgba(10,20,30,0.5)")?.alpha == 0.5)
        #expect(ConfigColor("rgb(300,-5,0)") == ConfigColor(red: 255, green: 0, blue: 0))
        #expect(ConfigColor("#ff0000") == nil)
        #expect(ConfigColor("rgb(1,2)") == nil)
        #expect(ConfigColor("nonsense") == nil)
        #expect(ConfigColor(red: 61, green: 174, blue: 233).cssString == "rgb(61,174,233)")
        #expect(ConfigColor(red: 1, green: 2, blue: 3, alpha: 0.5).cssString == "rgba(1,2,3,0.5)")
        #expect(ConfigColor.fallback.cssString == FaugusConfig
            .defaults(paths: .live, language: "en_US")["background-color"]?.stringValue)
    }

    @Test func sizesAreFormattedLikeUpstream() {
        #expect(LogsMaintenance.formatSize(0) == "0.0 B")
        #expect(LogsMaintenance.formatSize(1023) == "1023.0 B")
        #expect(LogsMaintenance.formatSize(1536) == "1.5 KB")
        #expect(LogsMaintenance.formatSize(5 * 1024 * 1024) == "5.0 MB")
        #expect(LogsMaintenance.formatSize(3 * 1024 * 1024 * 1024) == "3.0 GB")
        #expect(LogsMaintenance.formatSize(2 * 1024 * 1024 * 1024 * 1024) == "2.0 TB")
    }

    @Test func clearingLogsEmptiesTheFolderButKeepsIt() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        #expect(LogsMaintenance.size(of: paths.logsDirectory) == nil || LogsMaintenance.size(of: paths.logsDirectory) == 0)
        try FileManager.default.createDirectory(
            atPath: paths.gameLogsDirectory(gameID: "g"),
            withIntermediateDirectories: true
        )
        try Data(count: 2048).write(to: URL(fileURLWithPath: paths.gameLogsDirectory(gameID: "g") + "/wine.log"))
        try Data(count: 100).write(to: URL(fileURLWithPath: paths.logsDirectory + "/faugus.log"))
        #expect(LogsMaintenance.size(of: paths.logsDirectory) == 2148)
        try LogsMaintenance.clear(paths: paths)
        #expect(LogsMaintenance.size(of: paths.logsDirectory) == 0)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.logsDirectory, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}

@Suite("Interface mode rules")
struct InterfaceModeTests {
    @Test func optionsFollowUpstreamEnableRules() {
        #expect(InterfaceMode(configValue: "Covers") == .covers)
        #expect(InterfaceMode(configValue: "\"Grid\"") == .grid)
        #expect(InterfaceMode(configValue: "bogus") == .list)

        #expect(!InterfaceMode.list.supportsLabelsAndZoom)
        #expect(!InterfaceMode.grid.supportsLabelsAndZoom)
        #expect(InterfaceMode.covers.supportsLabelsAndZoom)
        #expect(InterfaceMode.carrousel.supportsLabelsAndZoom)

        #expect(InterfaceMode.covers.supportsBanner(steamGridDBEnabled: true))
        #expect(!InterfaceMode.covers.supportsBanner(steamGridDBEnabled: false))
        #expect(!InterfaceMode.grid.supportsBanner(steamGridDBEnabled: true))

        #expect(!InterfaceMode.list.supportsPosition && InterfaceMode.carrousel.supportsPosition)
        #expect(!InterfaceMode.list.supportsStartupWindowSize && InterfaceMode.grid.supportsStartupWindowSize)
        #expect(InterfaceMode.grid.supportsOrientation && InterfaceMode.covers.supportsOrientation)
        #expect(!InterfaceMode.carrousel.supportsOrientation && !InterfaceMode.carrousel.supportsMaxChildren)
        #expect(InterfaceMode.maxChildrenLabel(orientation: "Horizontal") == "Maximum Rows")
        #expect(InterfaceMode.maxChildrenLabel(orientation: "Vertical") == "Maximum Columns")
    }
}
