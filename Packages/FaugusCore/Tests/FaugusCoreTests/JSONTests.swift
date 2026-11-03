@testable import FaugusCore
import Foundation
import Testing

@Suite("JSON compatibility with Python json.dump(indent=4, ensure_ascii=False)")
struct JSONTests {
    @Test(
        "Upstream-style fixtures re-serialize byte for byte",
        arguments: [
            "config.default.json", "config.upstream.json", "game_fields.json",
            "games.upstream.json", "games.extra-fields.json", "games.empty.json",
        ]
    )
    func roundTripIsByteIdentical(name: String) throws {
        let original = try TestSupport.fixtureData(name)
        let value = try JSONParser.parse(original)
        let written = JSONWriter.serialize(value)
        #expect(String(decoding: written, as: UTF8.self) == String(decoding: original, as: UTF8.self))
    }

    @Test func preservesKeyOrderAndOverwriteKeepsPosition() throws {
        var o = JSONObject()
        o["b"] = 1
        o["a"] = 2
        o["b"] = 3
        #expect(o.keys == ["b", "a"])
        o["b"] = nil
        #expect(o.keys == ["a"])
        let parsed = try JSONParser.parse(#"{"z":1,"y":2,"z":3}"#)
        #expect(parsed.objectValue?.keys == ["z", "y"])
        #expect(parsed.objectValue?["z"] == .int(3))
    }

    @Test func emptyContainersAndNesting() {
        let v: JSONValue = ["a": [], "b": [:], "c": [[1, 2], ["x": nil]]]
        let expected = """
        {
            "a": [],
            "b": {},
            "c": [
                [
                    1,
                    2
                ],
                {
                    "x": null
                }
            ]
        }
        """
        #expect(JSONWriter.string(v) == expected)
    }

    @Test func stringEscapingMatchesPython() throws {
        let s = "q\" b\\ n\n r\r t\t bs\u{08} ff\u{0C} nul\u{01} é 日本 😀 del\u{7f}"
        let out = JSONWriter.string(.string(s))
        #expect(out == "\"q\\\" b\\\\ n\\n r\\r t\\t bs\\b ff\\f nul\\u0001 é 日本 😀 del\u{7f}\"")
        #expect(try JSONParser.parse(out) == .string(s))
    }

    @Test func parsesUnicodeEscapesAndSurrogatePairs() throws {
        #expect(try JSONParser.parse(#""\u00e9\ud83d\ude00\/""#) == .string("é😀/"))
        #expect(try JSONParser.parse(#""\ud800""#) == .string("\u{FFFD}"))
    }

    @Test func numbers() throws {
        #expect(try JSONParser.parse("0") == .int(0))
        #expect(try JSONParser.parse("-12") == .int(-12))
        #expect(try JSONParser.parse("1.5") == .double(1.5))
        #expect(try JSONParser.parse("1e3") == .double(1000))
        #expect(JSONWriter.string(.double(0.25)) == "0.25")
        #expect(JSONWriter.string(.double(1)) == "1.0")
        #expect(JSONWriter.string(.double(1e-5)) == "1e-05")
        #expect(JSONWriter.string(.int(Int64.max)) == "9223372036854775807")
    }

    @Test(
        "Invalid documents are rejected",
        arguments: ["", "{", "[1,]", "{\"a\":}", "{'a':1}", "01", "1.", "\"\\x\"", "[1] x", "nul", "{\"a\" 1}"]
    )
    func rejectsInvalid(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test func atomicWriteCreatesParentsAndLeavesNoTemp() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let target = paths.home + "/a/b/c.json"
        try JSONFile.save(["k": "v"], to: target)
        try JSONFile.save(["k": "w"], to: target)
        #expect(JSONFile.load(target) == ["k": "w"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.home + "/a/b")
        #expect(siblings == ["c.json"])
    }

    @Test func loadFallbacks() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let missing = paths.home + "/nope.json"
        #expect(JSONFile.load(missing) == .array([]))
        #expect(JSONFile.load(missing, default: .object(JSONObject())) == .object(JSONObject()))
        #expect(try JSONFile.loadOrThrow(missing) == .array([]))

        let bad = paths.home + "/bad.json"
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: bad))
        #expect(JSONFile.load(bad) == .array([]))
        #expect(throws: JSONFileError.self) { try JSONFile.loadOrThrow(bad) }
    }
}
