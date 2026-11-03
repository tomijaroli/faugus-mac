@testable import FaugusCore
import Foundation
import Testing

@Suite("i18n")
struct I18nTests {
    @Test func parsesBasicEntriesContinuationsAndEscapes() {
        let catalogSource = #"""
        # comment
        msgid ""
        msgstr ""
        "Language: de\n"
        "Plural-Forms: nplurals=2; plural=n != 1;\n"

        #: faugus/a.py:1
        msgid "Hello"
        msgstr "Hallo"

        msgid "Multi"
        "line"
        msgstr "Mehr"
        "zeilig\n"

        msgctxt "menu"
        msgid "Open"
        msgstr "Öffnen"

        msgid "Quote \"x\" \\ tab\t"
        msgstr "Zitat \"x\" \\ tab\t"

        #, fuzzy
        msgid "Fuzzy"
        msgstr "Unscharf"

        msgid "Untranslated"
        msgstr ""

        #~ msgid "Obsolete"
        #~ msgstr "Veraltet"
        """#
        let catalog = POCatalog.parse(catalogSource)
        #expect(catalog.headers["Language"] == "de")
        #expect(catalog.translate("Hello") == "Hallo")
        #expect(catalog.translate("Multiline") == "Mehrzeilig\n")
        #expect(catalog.translate("Open", context: "menu") == "Öffnen")
        #expect(catalog.translate("Open") == nil)
        #expect(catalog.translate("Quote \"x\" \\ tab\t") == "Zitat \"x\" \\ tab\t")
        #expect(catalog.translate("Fuzzy") == nil)
        #expect(catalog.translate("Untranslated") == nil)
        #expect(catalog.translate("Obsolete") == nil)
        #expect(catalog.entryCount == 4)
    }

    @Test func pluralEntries() {
        let catalogSource = """
        msgid "file"
        msgid_plural "files"
        msgstr[0] "Datei"
        msgstr[1] "Dateien"
        """
        let catalog = POCatalog.parse(catalogSource)
        #expect(catalog.translate("file") == "Datei")
        #expect(catalog.entryCount == 2)
    }

    @Test func fuzzyFlagAppliesOnlyToTheNextEntry() {
        let catalogSource = """
        #, fuzzy, python-format
        msgid "A"
        msgstr "a"

        msgid "B"
        msgstr "b"
        """
        let catalog = POCatalog.parse(catalogSource)
        #expect(catalog.translate("A") == nil)
        #expect(catalog.translate("B") == "b")
    }

    @Test func translatorFallsBackToMsgidAndFormats() {
        let translator = Translator(
            languageCode: "de",
            catalogs: [POCatalog.parse("msgid \"Latest\"\nmsgstr \"Neueste\"")]
        )
        #expect(translator("Latest") == "Neueste")
        #expect(translator("Unknown") == "Unknown")
        #expect(Translator.fill("Proton {} ({})", arguments: ["A", "B"]) == "Proton A (B)")
        #expect(Translator.fill("{1} then {0}", arguments: ["a", "b"]) == "b then a")
        #expect(Translator.fill("100%% of %s", arguments: ["x"]) == "100% of x")
        #expect(Translator.fill("{{literal}}", arguments: []) == "{literal}")
        #expect(Translator.identity("anything") == "anything")
    }

    // MARK: Against the real upstream catalogs

    private var catalogs: LanguageCatalogs {
        LanguageCatalogs(localeDirectory: TestSupport.upstreamLanguagesDirectory)
    }

    @Test func upstreamHasTwentySevenLanguages() throws {
        let directories = try FileManager.default
            .contentsOfDirectory(atPath: TestSupport.upstreamLanguagesDirectory.path)
            .filter { catalogs.poURL(language: $0, domain: "faugus-launcher") != nil }
        #expect(directories.count == 27)
    }

    @Test func germanTranslatesCoreStrings() {
        let translator = catalogs.translator(for: "de")
        #expect(translator("Prefix") == "Präfix")
        #expect(translator("Game") == "Spiel")
        #expect(translator("Settings") != "Settings")
        #expect(translator("A string that does not exist") == "A string that does not exist")
    }

    @Test func regionFallsBackToLanguage() {
        #expect(catalogs.translator(for: "de_DE")("Game") == "Spiel")
        #expect(catalogs.translator(for: "pt_BR").languageCode == "pt_BR")
        #expect(catalogs.translator(for: "xx_YY").languageCode == "xx_YY")
        #expect(catalogs.translator(for: "xx_YY")("Game") == "Game")
    }

    /// The ground truth is produced by Tools/gen-fixtures/gen.py with the real `msgfmt` and
    /// Python's `gettext`, exactly like upstream computes completions at runtime.
    @Test func entryCountsMatchMsgfmt() throws {
        let truth = try JSONParser.parse(TestSupport.fixtureData("translation-counts.json")).objectValue!
        let counts = truth["counts"]!.objectValue!
        #expect(counts.count == 27)
        for (language, expected) in counts.pairs {
            let catalog = catalogs.catalog(language: language, domain: "faugus-launcher")
            #expect(catalog?.entryCount == Int(expected.intValue!), "entry count for \(language)")
        }
    }

    @Test func completionPercentagesMatchUpstreamFormula() throws {
        let truth = try JSONParser.parse(TestSupport.fixtureData("translation-counts.json")).objectValue!
        let percent = truth["percent"]!.objectValue!
        let ours = catalogs.completions()
        #expect(ours.count == percent.count)
        for (language, expected) in percent.pairs {
            #expect(abs(ours[language]! - expected.doubleValue!) < 1e-9, "percent for \(language)")
        }
    }

    @Test func completionsAndThreshold() {
        let completions = catalogs.completions()
        #expect(completions.count == 27)
        #expect(completions.values.max()! == 100.0)
        #expect(completions.values.allSatisfy { $0 >= 0 && $0 <= 100 })
        // Known gaps in 2.5.6: these fall below the 70% line and are not offered in Settings.
        for language in ["ar", "cs", "ta", "fi", "nl", "nb"] {
            #expect(!catalogs.selectableLanguages().contains(language))
        }

        let selectable = catalogs.selectableLanguages()
        #expect(selectable.contains("en_US"))
        #expect(selectable.contains("de"))
        for language in selectable where language != "en_US" {
            #expect(completions[language]! >= 70)
        }
        for (language, percent) in completions where percent < 70 {
            #expect(!selectable.contains(language))
        }
    }

    @Test func rightToLeft() {
        #expect(LanguageCatalogs.isRightToLeft("ar"))
        #expect(LanguageCatalogs.isRightToLeft("fa"))
        #expect(!LanguageCatalogs.isRightToLeft("de"))
        #expect(!LanguageCatalogs.isRightToLeft("pt_BR"))
    }
}
