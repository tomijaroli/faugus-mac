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
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let cfg = try FaugusConfig.load(paths: paths, language: "de")
        #expect(FileManager.default.fileExists(atPath: paths.configFile))
        #expect(cfg.string("language") == "de")
        #expect(cfg.values["mac-graphics-backend"] == nil)
        #expect(cfg.macGraphicsBackend == "dxvk")
    }

    @Test func upstreamConfigIsNotRewrittenOrBackfilled() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "config.upstream.json", at: paths.configFile)
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.configFile))

        let cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        try cfg.save()

        let after = try Data(contentsOf: URL(fileURLWithPath: paths.configFile))
        #expect(after == before)
        #expect(cfg.string("language") == "pt_BR")
        #expect(cfg.string("default-runner") == "Proton-CachyOS Latest")
        #expect(cfg.int("playtime") == 14400)
        #expect(cfg.bool("system-tray"))
        #expect(cfg.values["mac-graphics-backend"] == nil)
    }

    @Test func missingKeysAreAddedAtTheEnd() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try JSONFile.save(["language": "fr", "custom-user-key": "keep"], to: paths.configFile)
        let cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(cfg.string("language") == "fr")
        #expect(cfg.string("custom-user-key") == "keep")
        #expect(cfg.values.keys.first == "language")
        #expect(cfg.values.keys.count == 68 + 1)

        let reloaded = JSONFile.load(paths.configFile).objectValue!
        #expect(reloaded.keys == cfg.values.keys)
    }

    @Test func setValueRulesMirrorUpstream() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        var cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        cfg.setValue("not-a-real-key", "x")
        #expect(cfg.values["not-a-real-key"] == nil)
        cfg.setValue("system-tray", bool: true)
        #expect(cfg.values["system-tray"] == "True")
        cfg.setValue("width", "1920")
        #expect(cfg.values["width"] == "1920")
        cfg.setValue("mac-graphics-backend", "wined3d")
        #expect(cfg.macGraphicsBackend == "wined3d")
    }

    @Test func accentColorFollowsMode() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        var cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(cfg.accentColor() == "system")
        cfg.setValue("accent-mode", "custom")
        cfg.setValue("accent-color", "rgb(1,2,3)")
        #expect(cfg.accentColor() == "rgb(1,2,3)")
    }

    @Test func invalidConfigFileFallsBackToDefaults() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try FileManager.default.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: paths.configFile))
        let cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        #expect(cfg.string("interface-mode") == "List")
    }
}

@Suite("Paths and locale")
struct PathsTests {
    @Test func layout() {
        let p = FaugusPaths(home: "/Users/u")
        #expect(p.configFile == "/Users/u/Library/Application Support/Faugus/config/config.json")
        #expect(p.gamesJSON == "/Users/u/Library/Application Support/Faugus/data/games.json")
        #expect(p.runningGamesFile == "/Users/u/Library/Application Support/Faugus/state/running-games.json")
        #expect(p.gameLogsDir(gameID: "x") == "/Users/u/Library/Logs/Faugus/x")
        #expect(p.prefixesDir == "/Users/u/Faugus")
        #expect(p.defaultPrefix == "/Users/u/Faugus/default")
        #expect(p.stopFile(gameID: "x") == "/Users/u/Library/Application Support/Faugus/state/stop-x")
    }

    @Test func expand() {
        let p = FaugusPaths(home: "/Users/u")
        #expect(p.expand("~/Games") == "/Users/u/Games")
        #expect(p.expand("~") == "/Users/u")
        #expect(p.expand("") == "")
        #expect(p.expand("$FAUGUS_DEFINITELY_UNSET_VAR/x") == "$FAUGUS_DEFINITELY_UNSET_VAR/x")
        #expect(p.expand("${HOME}/x") == ProcessInfo.processInfo.environment["HOME"]! + "/x")
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
