@testable import FaugusCore
import Foundation
import Testing

@Suite("i18n")
struct I18nTests {
    @Test func parsesBasicEntriesContinuationsAndEscapes() {
        let po = #"""
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
        let c = POCatalog.parse(po)
        #expect(c.headers["Language"] == "de")
        #expect(c.translate("Hello") == "Hallo")
        #expect(c.translate("Multiline") == "Mehrzeilig\n")
        #expect(c.translate("Open", context: "menu") == "Öffnen")
        #expect(c.translate("Open") == nil)
        #expect(c.translate("Quote \"x\" \\ tab\t") == "Zitat \"x\" \\ tab\t")
        #expect(c.translate("Fuzzy") == nil)
        #expect(c.translate("Untranslated") == nil)
        #expect(c.translate("Obsolete") == nil)
        #expect(c.entryCount == 4)
    }

    @Test func pluralEntries() {
        let po = """
        msgid "file"
        msgid_plural "files"
        msgstr[0] "Datei"
        msgstr[1] "Dateien"
        """
        let c = POCatalog.parse(po)
        #expect(c.translate("file") == "Datei")
        #expect(c.entryCount == 2)
    }

    @Test func fuzzyFlagAppliesOnlyToTheNextEntry() {
        let po = """
        #, fuzzy, python-format
        msgid "A"
        msgstr "a"

        msgid "B"
        msgstr "b"
        """
        let c = POCatalog.parse(po)
        #expect(c.translate("A") == nil)
        #expect(c.translate("B") == "b")
    }

    @Test func translatorFallsBackToMsgidAndFormats() {
        let t = Translator(languageCode: "de", catalogs: [POCatalog.parse("msgid \"Latest\"\nmsgstr \"Neueste\"")])
        #expect(t("Latest") == "Neueste")
        #expect(t("Unknown") == "Unknown")
        #expect(Translator.fill("Proton {} ({})", args: ["A", "B"]) == "Proton A (B)")
        #expect(Translator.fill("{1} then {0}", args: ["a", "b"]) == "b then a")
        #expect(Translator.fill("100%% of %s", args: ["x"]) == "100% of x")
        #expect(Translator.fill("{{literal}}", args: []) == "{literal}")
        #expect(Translator.identity("anything") == "anything")
    }

    // MARK: Against the real upstream catalogs

    private var catalogs: LanguageCatalogs {
        LanguageCatalogs(localeDirectory: TestSupport.upstreamLanguagesDirectory)
    }

    @Test func upstreamHasTwentySevenLanguages() throws {
        let dirs = try FileManager.default.contentsOfDirectory(atPath: TestSupport.upstreamLanguagesDirectory.path)
            .filter { catalogs.poURL(language: $0, domain: "faugus-launcher") != nil }
        #expect(dirs.count == 27)
    }

    @Test func germanTranslatesCoreStrings() {
        let t = catalogs.translator(for: "de")
        #expect(t("Prefix") == "Präfix")
        #expect(t("Game") == "Spiel")
        #expect(t("Settings") != "Settings")
        #expect(t("A string that does not exist") == "A string that does not exist")
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
        for (lang, expected) in counts.pairs {
            let cat = catalogs.catalog(language: lang, domain: "faugus-launcher")
            #expect(cat?.entryCount == Int(expected.intValue!), "entry count for \(lang)")
        }
    }

    @Test func completionPercentagesMatchUpstreamFormula() throws {
        let truth = try JSONParser.parse(TestSupport.fixtureData("translation-counts.json")).objectValue!
        let percent = truth["percent"]!.objectValue!
        let ours = catalogs.completions()
        #expect(ours.count == percent.count)
        for (lang, expected) in percent.pairs {
            #expect(abs(ours[lang]! - expected.doubleValue!) < 1e-9, "percent for \(lang)")
        }
    }

    @Test func completionsAndThreshold() {
        let c = catalogs.completions()
        #expect(c.count == 27)
        #expect(c.values.max()! == 100.0)
        #expect(c.values.allSatisfy { $0 >= 0 && $0 <= 100 })
        // Known gaps in 2.5.6: these fall below the 70% line and are not offered in Settings.
        for lang in ["ar", "cs", "ta", "fi", "nl", "nb"] {
            #expect(!catalogs.selectableLanguages().contains(lang))
        }

        let selectable = catalogs.selectableLanguages()
        #expect(selectable.contains("en_US"))
        #expect(selectable.contains("de"))
        for lang in selectable where lang != "en_US" {
            #expect(c[lang]! >= 70)
        }
        for (lang, pct) in c where pct < 70 {
            #expect(!selectable.contains(lang))
        }
    }

    @Test func rightToLeft() {
        #expect(LanguageCatalogs.isRightToLeft("ar"))
        #expect(LanguageCatalogs.isRightToLeft("fa"))
        #expect(!LanguageCatalogs.isRightToLeft("de"))
        #expect(!LanguageCatalogs.isRightToLeft("pt_BR"))
    }
}
