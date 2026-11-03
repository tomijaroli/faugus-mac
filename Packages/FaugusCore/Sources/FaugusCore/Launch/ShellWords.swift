import Foundation

public enum ShellWordsError: Error, Equatable {
    case noClosingQuotation
    case noEscapedCharacter
}

/// `shlex.split(s, posix=True)` and `shlex.quote`, which upstream uses to turn the launch
/// command string back into argv (`launch_arguments` and `game_arguments` are free text).
public enum ShellWords {
    public static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        var iterator = text.unicodeScalars.makeIterator()

        func endWord() {
            if inWord {
                words.append(String(current))
                current = String.UnicodeScalarView()
                inWord = false
            }
        }

        while let scalar = iterator.next() {
            switch scalar {
            case " ", "\t", "\n", "\r":
                endWord()
            case "\\":
                guard let nextScalar = iterator.next() else { throw ShellWordsError.noEscapedCharacter }
                current.append(nextScalar)
                inWord = true
            case "'":
                inWord = true
                var closed = false
                while let nextScalar = iterator.next() {
                    if nextScalar == "'" {
                        closed = true
                        break
                    }
                    current.append(nextScalar)
                }
                if !closed {
                    throw ShellWordsError.noClosingQuotation
                }
            case "\"":
                inWord = true
                var closed = false
                while let nextScalar = iterator.next() {
                    if nextScalar == "\"" {
                        closed = true
                        break
                    }
                    if nextScalar == "\\" {
                        guard let escaped = iterator.next() else { throw ShellWordsError.noClosingQuotation }
                        // Inside double quotes a backslash only escapes `"` and `\`.
                        if escaped != "\"", escaped != "\\" {
                            current.append("\\")
                        }
                        current.append(escaped)
                    } else {
                        current.append(nextScalar)
                    }
                }
                if !closed {
                    throw ShellWordsError.noClosingQuotation
                }
            default:
                current.append(scalar)
                inWord = true
            }
        }
        endWord()
        return words
    }

    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")

    public static func quote(_ text: String) -> String {
        if text.isEmpty {
            return "''"
        }
        if text.allSatisfy({ safe.contains($0) }) {
            return text
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// `str.isidentifier()` for ASCII env names.
    public static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return text.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `extract_env_from_message`: leading-or-anywhere `KEY=value` tokens become environment
    /// entries (in order), everything else stays a command-line argument.
    public static func extractEnvironment(from words: [String])
        -> (environment: [(String, String)], arguments: [String])
    {
        var environment: [(String, String)] = []
        var arguments: [String] = []
        for word in words {
            if let equalsIndex = word.firstIndex(of: "="), isIdentifier(String(word[..<equalsIndex])) {
                environment.append((String(word[..<equalsIndex]), String(word[word.index(after: equalsIndex)...])))
            } else {
                arguments.append(word)
            }
        }
        return (environment, arguments)
    }
}
