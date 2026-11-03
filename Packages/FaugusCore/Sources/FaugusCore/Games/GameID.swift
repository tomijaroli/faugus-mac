import Foundation

/// Port of `format_title` and `unique_gameid` from `faugus/utils.py`.
public enum GameID {
    /// `title.strip().lower()`, drop anything that is not a Python `\w`, whitespace or `-`,
    /// then collapse whitespace runs into `-`.
    public static func format(title: String) -> String {
        let lowered = pythonStrip(title).lowercased()

        var kept = String.UnicodeScalarView()
        for s in lowered.unicodeScalars where isWordScalar(s) || isPythonSpace(s) || s == "-" {
            kept.append(s)
        }

        var out = String.UnicodeScalarView()
        var inSpace = false
        for s in kept {
            if isPythonSpace(s) {
                if !inSpace { out.append("-") }
                inSpace = true
            } else {
                out.append(s)
                inSpace = false
            }
        }
        return String(out)
    }

    public static func unique(base: String, existing: Set<String>) -> String {
        if base.isEmpty || !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: Python-compatible character classes

    /// `str.isspace()`.
    static func isPythonSpace(_ s: Unicode.Scalar) -> Bool {
        if (0x1C...0x1F).contains(s.value) { return true }
        return s.properties.isWhitespace
    }

    /// Python's `\w` on `str`: alphanumeric (letters and numbers) or underscore.
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s == "_" { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    static func pythonStrip(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, isPythonSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isPythonSpace(l) { scalars.removeLast() }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: scalars)
        return String(v)
    }
}
