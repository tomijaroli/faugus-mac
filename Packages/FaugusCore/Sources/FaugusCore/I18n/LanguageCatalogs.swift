import Foundation

/// Port of the language scanning in `language_config.py`.
///
/// `localeDirectory` holds one directory per language, each with `<domain>.po` (upstream layout:
/// `languages/de/faugus-launcher.po`).
public struct LanguageCatalogs: Sendable {
    public static let minTranslationPercent = 70.0
    public static let upstreamDomain = "faugus-launcher"
    public static let macDomain = "faugus-mac"

    public let localeDirectory: URL

    public init(localeDirectory: URL) {
        self.localeDirectory = localeDirectory
    }

    public func poURL(language: String, domain: String) -> URL? {
        let candidates = [
            localeDirectory.appendingPathComponent(language).appendingPathComponent("\(domain).po"),
            localeDirectory.appendingPathComponent(language).appendingPathComponent("LC_MESSAGES")
                .appendingPathComponent("\(domain).po"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func catalog(language: String, domain: String) -> POCatalog? {
        guard let url = poURL(language: language, domain: domain) else { return nil }
        return try? POCatalog.parse(contentsOf: url)
    }

    /// `scan_translation_completions`: percentage of the best-translated language's entry
    /// count, per language.
    public func completions(domain: String = LanguageCatalogs.upstreamDomain) -> [String: Double] {
        guard let languageDirectories = try? FileManager.default.contentsOfDirectory(atPath: localeDirectory.path)
        else {
            return [:]
        }
        var counts: [String: Int] = [:]
        for language in languageDirectories {
            if let languageCatalog = catalog(language: language, domain: domain) {
                counts[language] = languageCatalog.entryCount
            }
        }
        let total = counts.values.max() ?? 0
        guard total > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(total) * 100.0 }
    }

    /// `populate_languages`: `en_US` plus every language at or above the threshold.
    public func selectableLanguages(
        minPercent: Double = LanguageCatalogs.minTranslationPercent
    ) -> [String] {
        var languages = ["en_US"]
        for (language, percent) in completions() where language != "en_US" && percent >= minPercent {
            languages.append(language)
        }
        return languages.sorted()
    }

    /// Builds a translator for `language`, trying `pt_BR` then `pt`. The Mac-only domain wins
    /// over the upstream domain. Unknown languages yield an identity translator.
    public func translator(for language: String) -> Translator {
        for candidate in SystemLocale.candidates(for: language) {
            var catalogs: [POCatalog] = []
            if let macCatalog = catalog(language: candidate, domain: LanguageCatalogs.macDomain) {
                catalogs.append(macCatalog)
            }
            if let upstreamCatalog = catalog(language: candidate, domain: LanguageCatalogs.upstreamDomain) {
                catalogs.append(upstreamCatalog)
            }
            if !catalogs.isEmpty {
                return Translator(languageCode: candidate, catalogs: catalogs)
            }
        }
        return Translator(languageCode: language, catalogs: [])
    }

    /// Right-to-left languages mirror the layout.
    public static func isRightToLeft(_ language: String) -> Bool {
        let base = language.split(separator: "_").first.map(String.init) ?? language
        return ["ar", "fa", "he", "ps", "ur", "yi", "ckb", "dv", "sd"].contains(base)
    }
}
