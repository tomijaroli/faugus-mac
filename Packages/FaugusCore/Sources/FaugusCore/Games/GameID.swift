import Foundation

/// Port of `format_title` and `unique_gameid` from `faugus/utils.py`.
public enum GameID {
    /// `title.strip().lower()`, drop anything that is not a Python `\w`, whitespace or `-`,
    /// then collapse whitespace runs into `-`.
    public static func format(title: String) -> String {
        let lowered = pythonStrip(title).lowercased()

        var kept = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars where isWordScalar(scalar) || isPythonSpace(scalar) || scalar == "-" {
            kept.append(scalar)
        }

        var out = String.UnicodeScalarView()
        var inSpace = false
        for scalar in kept {
            if isPythonSpace(scalar) {
                if !inSpace {
                    out.append("-")
                }
                inSpace = true
            } else {
                out.append(scalar)
                inSpace = false
            }
        }
        return String(out)
    }

    public static func unique(base: String, existing: Set<String>) -> String {
        if base.isEmpty || !existing.contains(base) {
            return base
        }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    // MARK: Python-compatible character classes

    /// `str.isspace()`.
    static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        if (0x1C ... 0x1F).contains(scalar.value) {
            return true
        }
        return scalar.properties.isWhitespace
    }

    /// Python's `\w` on `str`: alphanumeric (letters and numbers) or underscore.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" {
            return true
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    static func pythonStrip(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, isPythonSpace(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, isPythonSpace(last) {
            scalars.removeLast()
        }
        var stripped = String.UnicodeScalarView()
        stripped.append(contentsOf: scalars)
        return String(stripped)
    }
}
