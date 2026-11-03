@testable import FaugusCore
import Testing

@Suite("shlex")
struct ShellWordsTests {
    /// Expectations were produced by Python's shlex.split / shlex.quote.
    @Test(
        "split matches Python",
        arguments: [
            (#"WINEDLLOVERRIDES="dxgi=n" PROTON_NO_ESYNC=1"#, ["WINEDLLOVERRIDES=dxgi=n", "PROTON_NO_ESYNC=1"]),
            (#"a 'b c' "d e" f\ g"#, ["a", "b c", "d e", "f g"]),
            (#"x "a\"b" "c\d" 'e\f'"#, ["x", "a\"b", "c\\d", "e\\f"]),
            ("", []),
            ("   ", []),
            ("FOO= bar", ["FOO=", "bar"]),
            ("''", [""]),
            (#"a"b"c"#, ["abc"]),
            (#"-windowed -w=1920 --opt="x y""#, ["-windowed", "-w=1920", "--opt=x y"]),
            ("é 'ü ñ'", ["é", "ü ñ"]),
        ]
    )
    func split(input: String, expected: [String]) throws {
        #expect(try ShellWords.split(input) == expected)
    }

    @Test func splitErrors() {
        #expect(throws: ShellWordsError.noClosingQuotation) { try ShellWords.split("a 'b") }
        #expect(throws: ShellWordsError.noClosingQuotation) { try ShellWords.split("a \"b") }
        #expect(throws: ShellWordsError.noEscapedCharacter) { try ShellWords.split("a\\") }
    }

    @Test(
        "quote matches Python",
        arguments: [
            ("", "''"), ("abc", "abc"), ("a b", "'a b'"), ("it's", #"'it'"'"'s'"#),
            ("a/b-c_d.e", "a/b-c_d.e"), ("ü", "'ü'"), ("$HOME", "'$HOME'"), ("a=b", "a=b"),
        ]
    )
    func quote(input: String, expected: String) {
        #expect(ShellWords.quote(input) == expected)
    }

    @Test func quoteSplitRoundTrip() throws {
        let words = ["a b", "it's", "", "$x", "é", "\"q\"", "back\\slash"]
        #expect(try ShellWords.split(ShellWords.join(words)) == words)
    }

    @Test func environmentExtractionMatchesUpstream() throws {
        let words = try ShellWords.split(#"FOO=1 BAR="a b" wrapper --flag=x 1BAD=z =x"#)
        let (environment, arguments) = ShellWords.extractEnvironment(from: words)
        #expect(environment.map { "\($0.0)=\($0.1)" } == ["FOO=1", "BAR=a b"])
        #expect(arguments == ["wrapper", "--flag=x", "1BAD=z", "=x"])
        #expect(ShellWords.isIdentifier("_a1"))
        #expect(!ShellWords.isIdentifier("1a"))
        #expect(!ShellWords.isIdentifier(""))
    }
}
