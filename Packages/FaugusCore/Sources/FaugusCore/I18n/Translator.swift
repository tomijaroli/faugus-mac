import Foundation

/// Looks messages up in an ordered list of catalogs (Mac domain first, then upstream) and
/// falls back to the msgid, like `gettext`.
public struct Translator: Sendable {
    public let languageCode: String
    private let catalogs: [POCatalog]

    public init(languageCode: String, catalogs: [POCatalog]) {
        self.languageCode = languageCode
        self.catalogs = catalogs
    }

    public static let identity = Translator(languageCode: "en_US", catalogs: [])

    public func callAsFunction(_ msgid: String) -> String { translate(msgid) }

    public func translate(_ msgid: String, context: String? = nil) -> String {
        for c in catalogs {
            if let t = c.translate(msgid, context: context) { return t }
        }
        return msgid
    }

    /// Fills `{}` / `{0}` / `%s` placeholders the way upstream's `"...".format(...)` and
    /// `%` calls do.
    public func format(_ msgid: String, _ args: String...) -> String {
        Translator.fill(translate(msgid), args: args)
    }

    public static func fill(_ template: String, args: [String]) -> String {
        var out = ""
        var auto = 0
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "{", next < template.endIndex {
                if template[next] == "{" { out.append("{"); i = template.index(after: next); continue }
                if let close = template[next...].firstIndex(of: "}") {
                    let inner = template[next..<close]
                    if inner.isEmpty {
                        if auto < args.count { out += args[auto] }
                        auto += 1
                        i = template.index(after: close); continue
                    }
                    if let n = Int(inner) {
                        if n < args.count { out += args[n] }
                        i = template.index(after: close); continue
                    }
                }
            } else if c == "}", next < template.endIndex, template[next] == "}" {
                out.append("}"); i = template.index(after: next); continue
            } else if c == "%", next < template.endIndex {
                if template[next] == "%" { out.append("%"); i = template.index(after: next); continue }
                if template[next] == "s" || template[next] == "d" {
                    if auto < args.count { out += args[auto] }
                    auto += 1
                    i = template.index(after: next); continue
                }
            }
            out.append(c)
            i = next
        }
        return out
    }
}
