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
    public var entryCount: Int { entries.count }

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
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) -> POCatalog {
        enum Field { case ctxt, id, idPlural, str(Int) }

        var entries: [String: String] = [:]
        var headers: [String: String] = [:]

        var ctxt: String?
        var msgid: String?
        var msgidPlural: String?
        var msgstr: [Int: String] = [:]
        var fuzzy = false
        var pendingFuzzy = false
        var current: Field?

        func flush() {
            defer {
                ctxt = nil; msgid = nil; msgidPlural = nil; msgstr = [:]; fuzzy = false
                current = nil
            }
            guard let id = msgid else { return }
            if id.isEmpty {
                // Header entry: always parsed, never counted.
                if let h = msgstr[0] {
                    for line in h.split(separator: "\n") {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces)
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                return
            }
            if fuzzy { return }
            let base = ctxt.map { $0 + "\u{4}" + id } ?? id
            if msgidPlural != nil {
                guard let first = msgstr[0], !first.isEmpty else { return }
                for (n, value) in msgstr where !value.isEmpty {
                    entries[n == 0 ? base : base + "\u{0}" + String(n)] = value
                }
            } else if let s = msgstr[0], !s.isEmpty {
                entries[base] = s
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); pendingFuzzy = false; continue }
            if line.hasPrefix("#~") { continue }  // obsolete
            if line.hasPrefix("#") {
                if msgid != nil { flush() }
                if line.hasPrefix("#,") {
                    let flags = line.dropFirst(2).split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    if flags.contains("fuzzy") { pendingFuzzy = true }
                }
                continue
            }
            if line.hasPrefix("msgctxt") {
                if msgid != nil { flush() }
                fuzzy = pendingFuzzy; pendingFuzzy = false
                ctxt = unquote(line.dropFirst("msgctxt".count)); current = .ctxt
            } else if line.hasPrefix("msgid_plural") {
                msgidPlural = unquote(line.dropFirst("msgid_plural".count)); current = .idPlural
            } else if line.hasPrefix("msgid") {
                if msgid != nil, !msgstr.isEmpty { flush() }
                if msgid == nil, ctxt == nil { fuzzy = pendingFuzzy; pendingFuzzy = false }
                msgid = unquote(line.dropFirst("msgid".count)); current = .id
            } else if line.hasPrefix("msgstr[") {
                guard let close = line.firstIndex(of: "]"),
                    let n = Int(line[line.index(line.startIndex, offsetBy: 7)..<close])
                else { continue }
                msgstr[n] = unquote(line[line.index(after: close)...])
                current = .str(n)
            } else if line.hasPrefix("msgstr") {
                msgstr[0] = unquote(line.dropFirst("msgstr".count)); current = .str(0)
            } else if line.hasPrefix("\"") {
                let piece = unquote(Substring(line))
                switch current {
                case .ctxt?: ctxt = (ctxt ?? "") + piece
                case .id?: msgid = (msgid ?? "") + piece
                case .idPlural?: msgidPlural = (msgidPlural ?? "") + piece
                case .str(let n)?: msgstr[n] = (msgstr[n] ?? "") + piece
                case nil: break
                }
            }
        }
        flush()
        return POCatalog(entries: entries, headers: headers)
    }

    /// Parses a (possibly prefixed with whitespace) `"..."` literal with C-style escapes.
    static func unquote(_ s: Substring) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return "" }
        let inner = t.dropFirst().dropLast()
        var out = String.UnicodeScalarView()
        var it = inner.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { break }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            default: out.append("\\"); out.append(e)
            }
        }
        return String(out)
    }
}
