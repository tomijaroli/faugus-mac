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

    public func callAsFunction(_ msgid: String) -> String {
        translate(msgid)
    }

    public func translate(_ msgid: String, context: String? = nil) -> String {
        for catalog in catalogs {
            if let translation = catalog.translate(msgid, context: context) {
                return translation
            }
        }
        return msgid
    }

    /// Fills `{}` / `{0}` / `%s` placeholders the way upstream's `"...".format(...)` and
    /// `%` calls do.
    public func format(_ msgid: String, _ arguments: String...) -> String {
        Translator.fill(translate(msgid), arguments: arguments)
    }

    public static func fill(_ template: String, arguments: [String]) -> String {
        var output = ""
        var automaticIndex = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{", next < template.endIndex {
                if template[next] == "{" {
                    output.append("{")
                    index = template.index(after: next)
                    continue
                }
                if let close = template[next...].firstIndex(of: "}") {
                    let inner = template[next ..< close]
                    if inner.isEmpty {
                        if automaticIndex < arguments.count {
                            output += arguments[automaticIndex]
                        }
                        automaticIndex += 1
                        index = template.index(after: close)
                        continue
                    }
                    if let explicitIndex = Int(inner) {
                        if explicitIndex < arguments.count {
                            output += arguments[explicitIndex]
                        }
                        index = template.index(after: close)
                        continue
                    }
                }
            } else if character == "}", next < template.endIndex, template[next] == "}" {
                output.append("}")
                index = template.index(after: next)
                continue
            } else if character == "%", next < template.endIndex {
                if template[next] == "%" {
                    output.append("%")
                    index = template.index(after: next)
                    continue
                }
                if template[next] == "s" || template[next] == "d" {
                    if automaticIndex < arguments.count {
                        output += arguments[automaticIndex]
                    }
                    automaticIndex += 1
                    index = template.index(after: next)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }
}
