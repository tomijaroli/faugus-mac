import Foundation

/// Maps macOS language identifiers onto upstream's `languages/<code>` directory names
/// (`de`, `pt_BR`, `zh_CN`, ...).
public enum SystemLocale {
    /// The user's preferred macOS language as an upstream-style code, e.g. `en_US`, `pt_BR`.
    public static func currentCode(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let first = preferred.first else { return "en_US" }
        return normalize(first)
    }

    /// `pt-BR` to `pt_BR`; `zh-Hans-CN` to `zh_CN`; `zh-Hant-TW` to `zh_TW`; `de` stays `de`.
    public static func normalize(_ identifier: String) -> String {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first else { return "en_US" }
        var region: String?
        var script: String?
        for part in parts.dropFirst() {
            if part.count == 4 {
                script = part
            } else if part.count == 2 || part.count == 3,
                      part.allSatisfy({ $0.isLetter || $0.isNumber })
            {
                region = part.uppercased()
            }
        }
        if language == "zh" {
            if let region {
                return "zh_\(region)"
            }
            return script == "Hant" ? "zh_TW" : "zh_CN"
        }
        if let region {
            return "\(language)_\(region)"
        }
        return language == "en" ? "en_US" : language
    }

    /// Candidate catalog directory names for `code`, most specific first, matching what a
    /// gettext install would do: `pt_BR`, `pt`; then `en` is the implicit source language.
    public static func candidates(for code: String) -> [String] {
        var directoryNames = [code]
        if let underscoreIndex = code.firstIndex(of: "_") {
            directoryNames.append(String(code[..<underscoreIndex]))
        }
        return directoryNames
    }
}
