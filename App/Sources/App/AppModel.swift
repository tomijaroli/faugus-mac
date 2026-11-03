import FaugusCore
import Foundation
import Observation

/// Shared state for the launcher UI: paths, config, translations and the games list.
@MainActor
@Observable
final class AppModel {
    let paths: FaugusPaths
    private(set) var config: FaugusConfig?
    private(set) var games: [Game] = []
    private(set) var translator: Translator = .identity
    private(set) var languageCode: String = "en_US"
    private(set) var loadError: String?

    var isRightToLeft: Bool { LanguageCatalogs.isRightToLeft(languageCode) }

    init(paths: FaugusPaths = .live) {
        self.paths = paths
        reload()
    }

    func reload() {
        do {
            try paths.ensureDirectories()
            let cfg = try FaugusConfig.load(paths: paths)
            config = cfg
            // `FAUGUS_LANG` is a QA override that never touches config.json.
            languageCode = ProcessInfo.processInfo.environment["FAUGUS_LANG"] ?? cfg.string("language", default: "en_US")
            translator = Self.languageCatalogs()?.translator(for: languageCode) ?? .identity
            games = try GamesStore(paths: paths).load(showHidden: cfg.bool("show-hidden"))
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    /// `Contents/Resources/languages`, or `FAUGUS_LANGUAGES_DIR` when running unbundled.
    static func languageCatalogs() -> LanguageCatalogs? {
        if let override = ProcessInfo.processInfo.environment["FAUGUS_LANGUAGES_DIR"] {
            return LanguageCatalogs(localeDir: URL(fileURLWithPath: override))
        }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("languages"),
            FileManager.default.fileExists(atPath: dir.path)
        else { return nil }
        return LanguageCatalogs(localeDir: dir)
    }
}
