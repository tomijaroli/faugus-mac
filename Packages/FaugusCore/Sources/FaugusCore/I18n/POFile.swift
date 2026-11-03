import Foundation

/// A parsed gettext catalog. The port reads upstream's `.po` files directly at runtime
/// instead of compiled `.mo` files, applying the same inclusion rules as `msgfmt`:
/// fuzzy entries, obsolete (`#~`) entries and untranslated entries are skipped.
public struct POCatalog: Equatable, Sendable {
    /// `msgctxt EOT msgid` (or just `msgid`) mapped to the translation. Plural entries
    /// are stored under `msgid` for form 0 and `msgid` + `\u{0}` + `n` for the others.
    public let entries: [String: String]
    public let headers: [String: String]

    /// Same number `len([k for k in translation._catalog if k != ''])` gives for a `.mo`.
    public var entryCount: Int {
        entries.count
    }

    public func translate(_ msgid: String, context: String? = nil) -> String? {
        let key = context.map { $0 + "\u{4}" + msgid } ?? msgid
        guard let value = entries[key], !value.isEmpty else { return nil }
        return value
    }

    public static let empty = POCatalog(entries: [:], headers: [:])

    public init(entries: [String: String], headers: [String: String]) {
        self.entries = entries
        self.headers = headers
    }

    // MARK: Parsing

    public static func parse(contentsOf url: URL) throws -> POCatalog {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    // A single-pass state machine over the file; splitting it would scatter the state.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func parse(_ text: String) -> POCatalog {
        enum Field { case context, id, idPlural, translation(Int) }

        var entries: [String: String] = [:]
        var headers: [String: String] = [:]

        var context: String?
        var msgid: String?
        var msgidPlural: String?
        var msgstr: [Int: String] = [:]
        var fuzzy = false
        var pendingFuzzy = false
        var current: Field?

        func flush() {
            defer {
                context = nil
                msgid = nil
                msgidPlural = nil
                msgstr = [:]
                fuzzy = false
                current = nil
            }
            guard let id = msgid else { return }
            if id.isEmpty {
                // Header entry: always parsed, never counted.
                if let headerText = msgstr[0] {
                    for line in headerText.split(separator: "\n") {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let headerName = line[..<colon].trimmingCharacters(in: .whitespaces)
                        let headerValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[headerName] = headerValue
                    }
                }
                return
            }
            if fuzzy {
                return
            }
            let base = context.map { $0 + "\u{4}" + id } ?? id
            if msgidPlural != nil {
                guard let first = msgstr[0], !first.isEmpty else { return }
                for (form, value) in msgstr where !value.isEmpty {
                    entries[form == 0 ? base : base + "\u{0}" + String(form)] = value
                }
            } else if let translation = msgstr[0], !translation.isEmpty {
                entries[base] = translation
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                pendingFuzzy = false
                continue
            }
            if line.hasPrefix("#~") {
                continue
            } // obsolete
            if line.hasPrefix("#") {
                if msgid != nil {
                    flush()
                }
                if line.hasPrefix("#,") {
                    let flags = line.dropFirst(2).split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    if flags.contains("fuzzy") {
                        pendingFuzzy = true
                    }
                }
                continue
            }
            if line.hasPrefix("msgctxt") {
                if msgid != nil {
                    flush()
                }
                fuzzy = pendingFuzzy
                pendingFuzzy = false
                context = unquote(line.dropFirst("msgctxt".count))
                current = .context
            } else if line.hasPrefix("msgid_plural") {
                msgidPlural = unquote(line.dropFirst("msgid_plural".count))
                current = .idPlural
            } else if line.hasPrefix("msgid") {
                if msgid != nil, !msgstr.isEmpty {
                    flush()
                }
                if msgid == nil, context == nil {
                    fuzzy = pendingFuzzy
                    pendingFuzzy = false
                }
                msgid = unquote(line.dropFirst("msgid".count))
                current = .id
            } else if line.hasPrefix("msgstr[") {
                guard let close = line.firstIndex(of: "]"),
                      let form = Int(line[line.index(line.startIndex, offsetBy: 7) ..< close])
                else { continue }
                msgstr[form] = unquote(line[line.index(after: close)...])
                current = .translation(form)
            } else if line.hasPrefix("msgstr") {
                msgstr[0] = unquote(line.dropFirst("msgstr".count))
                current = .translation(0)
            } else if line.hasPrefix("\"") {
                let piece = unquote(Substring(line))
                switch current {
                case .context?: context = (context ?? "") + piece
                case .id?: msgid = (msgid ?? "") + piece
                case .idPlural?: msgidPlural = (msgidPlural ?? "") + piece
                case let .translation(form)?: msgstr[form] = (msgstr[form] ?? "") + piece
                case nil: break
                }
            }
        }
        flush()
        return POCatalog(entries: entries, headers: headers)
    }

    /// Parses a (possibly prefixed with whitespace) `"..."` literal with C-style escapes.
    static func unquote(_ quotedText: Substring) -> String {
        let trimmed = quotedText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else { return "" }
        let inner = trimmed.dropFirst().dropLast()
        var unescaped = String.UnicodeScalarView()
        var iterator = inner.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else { unescaped.append(scalar)
                continue
            }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": unescaped.append("\n")
            case "t": unescaped.append("\t")
            case "r": unescaped.append("\r")
            case "\"": unescaped.append("\"")
            case "\\": unescaped.append("\\")
            case "a": unescaped.append("\u{07}")
            case "b": unescaped.append("\u{08}")
            case "f": unescaped.append("\u{0C}")
            case "v": unescaped.append("\u{0B}")
            default: unescaped.append("\\")
                unescaped.append(escaped)
            }
        }
        return String(unescaped)
    }
}
