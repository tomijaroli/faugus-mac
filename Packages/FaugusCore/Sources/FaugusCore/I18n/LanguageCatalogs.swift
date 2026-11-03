import Foundation

/// Port of the language scanning in `language_config.py`.
///
/// `localeDir` holds one directory per language, each with `<domain>.po` (upstream layout:
/// `languages/de/faugus-launcher.po`).
public struct LanguageCatalogs: Sendable {
    public static let minTranslationPercent = 70.0
    public static let upstreamDomain = "faugus-launcher"
    public static let macDomain = "faugus-mac"

    public let localeDir: URL

    public init(localeDir: URL) {
        self.localeDir = localeDir
    }

    public func poURL(language: String, domain: String) -> URL? {
        let candidates = [
            localeDir.appendingPathComponent(language).appendingPathComponent("\(domain).po"),
            localeDir.appendingPathComponent(language).appendingPathComponent("LC_MESSAGES")
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
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: localeDir.path) else {
            return [:]
        }
        var counts: [String: Int] = [:]
        for lang in dirs {
            if let c = catalog(language: lang, domain: domain) {
                counts[lang] = c.entryCount
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
        var langs = ["en_US"]
        for (lang, pct) in completions() where lang != "en_US" && pct >= minPercent {
            langs.append(lang)
        }
        return langs.sorted()
    }

    /// Builds a translator for `language`, trying `pt_BR` then `pt`. The Mac-only domain wins
    /// over the upstream domain. Unknown languages yield an identity translator.
    public func translator(for language: String) -> Translator {
        for candidate in SystemLocale.candidates(for: language) {
            var catalogs: [POCatalog] = []
            if let mac = catalog(language: candidate, domain: LanguageCatalogs.macDomain) {
                catalogs.append(mac)
            }
            if let up = catalog(language: candidate, domain: LanguageCatalogs.upstreamDomain) {
                catalogs.append(up)
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
