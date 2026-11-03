@testable import FaugusCore
import Foundation
import Testing

@Suite("config.json")
struct ConfigTests {
    @Test func defaultsMatchUpstreamKeysOrderAndValues() throws {
        let upstream = try JSONParser.parse(TestSupport.fixtureData("config.default.json")).objectValue!
        let paths = FaugusPaths(home: "/Users/test")
        let ours = FaugusConfig.defaults(paths: paths, language: "en_US")

        #expect(ours.keys == upstream.keys)

        // Documented deviations: default-runner, default-prefix (macOS home), language.
        let deviations: Set = ["default-runner", "default-prefix", "language"]
        for (key, value) in upstream.pairs where !deviations.contains(key) {
            #expect(ours[key] == value, "default for \(key)")
        }
        #expect(ours["default-runner"] == "Wine-Staging Latest")
        #expect(ours["default-prefix"] == "/Users/test/Faugus")
        #expect(upstream["default-prefix"] == "<PREFIXES_DIR>")
        #expect(upstream["language"] == "<lang>")
    }

    @Test func firstRunWritesAllDefaults() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let configuration = try FaugusConfig.load(paths: paths, language: "de")
        #expect(FileManager.default.fileExists(atPath: paths.configFile))
        #expect(configuration.string("language") == "de")
        #expect(configuration.values["mac-graphics-backend"] == nil)
        #expect(configuration.macGraphicsBackend == "dxvk")
    }

    @Test func upstreamConfigIsNotRewrittenOrBackfilled() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "config.upstream.json", at: paths.configFile)
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.configFile))

        let configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        try configuration.save()

        let after = try Data(contentsOf: URL(fileURLWithPath: paths.configFile))
        #expect(after == before)
        #expect(configuration.string("language") == "pt_BR")
        #expect(configuration.string("default-runner") == "Proton-CachyOS Latest")
        #expect(configuration.int("playtime") == 14400)
        #expect(configuration.bool("system-tray"))
        #expect(configuration.values["mac-graphics-backend"] == nil)
    }

    @Test func missingKeysAreAddedAtTheEnd() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try JSONFile.save(["language": "fr", "custom-user-key": "keep"], to: paths.configFile)
        let configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(configuration.string("language") == "fr")
        #expect(configuration.string("custom-user-key") == "keep")
        #expect(configuration.values.keys.first == "language")
        #expect(configuration.values.keys.count == 68 + 1)

        let reloaded = JSONFile.load(paths.configFile).objectValue!
        #expect(reloaded.keys == configuration.values.keys)
    }

    @Test func setValueRulesMirrorUpstream() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setValue("not-a-real-key", "x")
        #expect(configuration.values["not-a-real-key"] == nil)
        configuration.setValue("system-tray", bool: true)
        #expect(configuration.values["system-tray"] == "True")
        configuration.setValue("width", "1920")
        #expect(configuration.values["width"] == "1920")
        configuration.setValue("mac-graphics-backend", "wined3d")
        #expect(configuration.macGraphicsBackend == "wined3d")
    }

    @Test func accentColorFollowsMode() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(configuration.accentColor() == "system")
        configuration.setValue("accent-mode", "custom")
        configuration.setValue("accent-color", "rgb(1,2,3)")
        #expect(configuration.accentColor() == "rgb(1,2,3)")
    }

    @Test func invalidConfigFileFallsBackToDefaults() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try FileManager.default.createDirectory(atPath: paths.configDirectory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: paths.configFile))
        let configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(configuration.string("interface-mode") == "List")
    }
}

@Suite("Paths and locale")
struct PathsTests {
    @Test func layout() {
        let testPaths = FaugusPaths(home: "/Users/u")
        #expect(testPaths.configFile == "/Users/u/Library/Application Support/Faugus/config/config.json")
        #expect(testPaths.gamesJSON == "/Users/u/Library/Application Support/Faugus/data/games.json")
        #expect(testPaths.runningGamesFile == "/Users/u/Library/Application Support/Faugus/state/running-games.json")
        #expect(testPaths.gameLogsDirectory(gameID: "x") == "/Users/u/Library/Logs/Faugus/x")
        #expect(testPaths.prefixesDirectory == "/Users/u/Faugus")
        #expect(testPaths.defaultPrefix == "/Users/u/Faugus/default")
        #expect(testPaths.stopFile(gameID: "x") == "/Users/u/Library/Application Support/Faugus/state/stop-x")
    }

    @Test func expand() {
        let testPaths = FaugusPaths(home: "/Users/u")
        #expect(testPaths.expand("~/Games") == "/Users/u/Games")
        #expect(testPaths.expand("~") == "/Users/u")
        #expect(testPaths.expand("") == "")
        #expect(testPaths.expand("$FAUGUS_DEFINITELY_UNSET_VAR/x") == "$FAUGUS_DEFINITELY_UNSET_VAR/x")
        #expect(testPaths.expand("${HOME}/x") == ProcessInfo.processInfo.environment["HOME"]! + "/x")
    }

    @Test func localeNormalization() {
        #expect(SystemLocale.normalize("pt-BR") == "pt_BR")
        #expect(SystemLocale.normalize("zh-Hans-CN") == "zh_CN")
        #expect(SystemLocale.normalize("zh-Hant-TW") == "zh_TW")
        #expect(SystemLocale.normalize("zh-Hant") == "zh_TW")
        #expect(SystemLocale.normalize("de-DE") == "de_DE")
        #expect(SystemLocale.normalize("de") == "de")
        #expect(SystemLocale.normalize("en") == "en_US")
        #expect(SystemLocale.currentCode(preferred: []) == "en_US")
        #expect(SystemLocale.candidates(for: "pt_BR") == ["pt_BR", "pt"])
        #expect(SystemLocale.candidates(for: "de") == ["de"])
    }
}
