import Foundation

/// A value in Valve's text KeyValues format (`.vdf`, `.acf`).
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDFValue)])

    public static func == (a: VDFValue, b: VDFValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var entries: [(key: String, value: VDFValue)] {
        if case .object(let e) = self { return e }
        return []
    }

    /// Steam writes keys with inconsistent case (`Software`/`software`), so lookups ignore it.
    /// When a key repeats, the last one wins (as with Python's `vdf` module).
    public subscript(key: String) -> VDFValue? {
        let lower = key.lowercased()
        return entries.last { $0.key.lowercased() == lower }?.value
    }

    public func path(_ keys: String...) -> VDFValue? {
        var current: VDFValue? = self
        for k in keys { current = current?[k] }
        return current
    }
}

/// Parser for text VDF. Lenient like Steam's own: unknown escapes are kept, a missing closing
/// brace ends the object at end of input, `//` comments are skipped. Never traps on bad input.
public enum VDF {
    public static func parse(_ text: String) -> VDFValue? {
        var p = Parser(Array(text.unicodeScalars))
        let entries = p.parseEntries(topLevel: true)
        return p.failed ? nil : .object(entries)
    }

    public static func parse(file path: String) -> VDFValue? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Steam writes UTF-8; tolerate stray bytes like Python's `errors="ignore"`.
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var failed = false
        var depth = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skipSpace() {
            while i < s.count {
                if s[i].properties.isWhitespace || s[i] == "\u{FEFF}" {
                    i += 1
                } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        /// A quoted or bare token; nil at `}` / end of input.
        mutating func token() -> String? {
            skipSpace()
            guard i < s.count, s[i] != "}" else { return nil }
            var out = String.UnicodeScalarView()
            if s[i] == "\"" {
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "\\", i + 1 < s.count {
                        switch s[i + 1] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "\\": out.append("\\")
                        case "\"": out.append("\"")
                        default: out.append(s[i]); out.append(s[i + 1])
                        }
                        i += 2
                    } else {
                        out.append(s[i])
                        i += 1
                    }
                }
                i += 1  // closing quote
            } else {
                while i < s.count, !s[i].properties.isWhitespace, s[i] != "{", s[i] != "}", s[i] != "\"" {
                    out.append(s[i])
                    i += 1
                }
                if out.isEmpty { i += 1; failed = true; return nil }
            }
            return String(out)
        }

        mutating func parseEntries(topLevel: Bool) -> [(key: String, value: VDFValue)] {
            var result: [(key: String, value: VDFValue)] = []
            depth += 1
            defer { depth -= 1 }
            if depth > 64 { failed = true; return result }
            while !failed {
                guard let key = token() else { break }
                skipSpace()
                guard i < s.count else { failed = true; break }
                if s[i] == "{" {
                    i += 1
                    result.append((key, .object(parseEntries(topLevel: false))))
                    skipSpace()
                    if i < s.count, s[i] == "}" { i += 1 }
                } else if let value = token() {
                    result.append((key, .string(value)))
                } else {
                    failed = true
                }
            }
            if topLevel, i < s.count, s[i] == "}" { failed = true }
            return result
        }
    }
}
