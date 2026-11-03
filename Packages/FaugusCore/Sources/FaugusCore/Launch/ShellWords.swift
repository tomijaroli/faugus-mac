import Foundation

public enum ShellWordsError: Error, Equatable {
    case noClosingQuotation
    case noEscapedCharacter
}

/// `shlex.split(s, posix=True)` and `shlex.quote`, which upstream uses to turn the launch
/// command string back into argv (`launch_arguments` and `game_arguments` are free text).
public enum ShellWords {
    public static func split(_ s: String) throws -> [String] {
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        var inWord = false
        var it = s.unicodeScalars.makeIterator()

        func endWord() {
            if inWord {
                words.append(String(cur))
                cur = String.UnicodeScalarView()
                inWord = false
            }
        }

        while let c = it.next() {
            switch c {
            case " ", "\t", "\n", "\r":
                endWord()
            case "\\":
                guard let n = it.next() else { throw ShellWordsError.noEscapedCharacter }
                cur.append(n)
                inWord = true
            case "'":
                inWord = true
                var closed = false
                while let n = it.next() {
                    if n == "'" {
                        closed = true
                        break
                    }
                    cur.append(n)
                }
                if !closed {
                    throw ShellWordsError.noClosingQuotation
                }
            case "\"":
                inWord = true
                var closed = false
                while let n = it.next() {
                    if n == "\"" {
                        closed = true
                        break
                    }
                    if n == "\\" {
                        guard let e = it.next() else { throw ShellWordsError.noClosingQuotation }
                        // Inside double quotes a backslash only escapes `"` and `\`.
                        if e != "\"", e != "\\" {
                            cur.append("\\")
                        }
                        cur.append(e)
                    } else {
                        cur.append(n)
                    }
                }
                if !closed {
                    throw ShellWordsError.noClosingQuotation
                }
            default:
                cur.append(c)
                inWord = true
            }
        }
        endWord()
        return words
    }

    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")

    public static func quote(_ s: String) -> String {
        if s.isEmpty {
            return "''"
        }
        if s.allSatisfy({ safe.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// `str.isidentifier()` for ASCII env names.
    public static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `extract_env_from_message`: leading-or-anywhere `KEY=value` tokens become environment
    /// entries (in order), everything else stays argv.
    public static func extractEnvironment(from words: [String]) -> (env: [(String, String)], argv: [String]) {
        var env: [(String, String)] = []
        var argv: [String] = []
        for w in words {
            if let eq = w.firstIndex(of: "="), isIdentifier(String(w[..<eq])) {
                env.append((String(w[..<eq]), String(w[w.index(after: eq)...])))
            } else {
                argv.append(w)
            }
        }
        return (env, argv)
    }
}
