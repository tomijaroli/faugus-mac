import Foundation

/// A value in Valve's text KeyValues format (`.vdf`, `.acf`).
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDFValue)])

    public static func == (left: VDFValue, right: VDFValue) -> Bool {
        switch (left, right) {
        case let (.string(x), .string(y)): x == y
        case let (.object(x), .object(y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public var string: String? {
        if case let .string(text) = self {
            return text
        }
        return nil
    }

    public var entries: [(key: String, value: VDFValue)] {
        if case let .object(objectEntries) = self {
            return objectEntries
        }
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
        for key in keys {
            current = current?[key]
        }
        return current
    }
}

/// Parser for text VDF. Lenient like Steam's own: unknown escapes are kept, a missing closing
/// brace ends the object at end of input, `//` comments are skipped. Never traps on bad input.
public enum VDF {
    public static func parse(_ text: String) -> VDFValue? {
        var parser = Parser(Array(text.unicodeScalars))
        let entries = parser.parseEntries(topLevel: true)
        return parser.failed ? nil : .object(entries)
    }

    public static func parse(file path: String) -> VDFValue? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Steam writes UTF-8; tolerate stray bytes like Python's `errors="ignore"`.
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0
        var failed = false
        var depth = 0
        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        mutating func skipSpace() {
            while position < scalars.count {
                if scalars[position].properties.isWhitespace || scalars[position] == "\u{FEFF}" {
                    position += 1
                } else if scalars[position] == "/", position + 1 < scalars.count, scalars[position + 1] == "/" {
                    while position < scalars.count, scalars[position] != "\n" {
                        position += 1
                    }
                } else {
                    break
                }
            }
        }

        /// A quoted or bare token; nil at `}` / end of input.
        mutating func token() -> String? {
            skipSpace()
            guard position < scalars.count, scalars[position] != "}" else { return nil }
            var tokenScalars = String.UnicodeScalarView()
            if scalars[position] == "\"" {
                position += 1
                while position < scalars.count, scalars[position] != "\"" {
                    if scalars[position] == "\\", position + 1 < scalars.count {
                        switch scalars[position + 1] {
                        case "n": tokenScalars.append("\n")
                        case "t": tokenScalars.append("\t")
                        case "\\": tokenScalars.append("\\")
                        case "\"": tokenScalars.append("\"")
                        default: tokenScalars.append(scalars[position])
                            tokenScalars.append(scalars[position + 1])
                        }
                        position += 2
                    } else {
                        tokenScalars.append(scalars[position])
                        position += 1
                    }
                }
                position += 1 // closing quote
            } else {
                while position < scalars.count, !scalars[position].properties.isWhitespace, scalars[position] != "{",
                      scalars[position] != "}", scalars[position] != "\""
                {
                    tokenScalars.append(scalars[position])
                    position += 1
                }
                if tokenScalars.isEmpty {
                    position += 1
                    failed = true
                    return nil
                }
            }
            return String(tokenScalars)
        }

        mutating func parseEntries(topLevel: Bool) -> [(key: String, value: VDFValue)] {
            var result: [(key: String, value: VDFValue)] = []
            depth += 1
            defer { depth -= 1 }
            if depth > 64 {
                failed = true
                return result
            }
            while !failed {
                guard let key = token() else { break }
                skipSpace()
                guard position < scalars.count else { failed = true
                    break
                }
                if scalars[position] == "{" {
                    position += 1
                    result.append((key, .object(parseEntries(topLevel: false))))
                    skipSpace()
                    if position < scalars.count, scalars[position] == "}" {
                        position += 1
                    }
                } else if let value = token() {
                    result.append((key, .string(value)))
                } else {
                    failed = true
                }
            }
            if topLevel, position < scalars.count, scalars[position] == "}" {
                failed = true
            }
            return result
        }
    }
}
