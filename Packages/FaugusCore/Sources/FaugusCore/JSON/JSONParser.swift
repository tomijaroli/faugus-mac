import Foundation

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

/// A small, strict, order-preserving JSON parser (RFC 8259, plus Python's `NaN`/`Infinity`
/// tokens are rejected, which is fine: upstream never writes them).
public enum JSONParser {
    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        p.skipBOM()
        p.skipWhitespace()
        let value = try p.parseValue(depth: 0)
        p.skipWhitespace()
        if !p.atEnd { throw p.error("unexpected trailing data") }
        return value
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        static let maxDepth = 512

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        func error(_ message: String) -> JSONParseError {
            JSONParseError(message: message, offset: i)
        }

        mutating func skipBOM() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        }

        mutating func skipWhitespace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < Parser.maxDepth else { throw error("nesting too deep") }
            guard i < bytes.count else { throw error("unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw error("unexpected character")
            }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard i + lit.count <= bytes.count, Array(bytes[i..<(i + lit.count)]) == lit else {
                throw error("invalid literal")
            }
            i += lit.count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1
            var obj = JSONObject()
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                    throw error("expected string key")
                }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
                i += 1
                skipWhitespace()
                obj[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard i < bytes.count else { throw error("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1
            var arr: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
            while true {
                skipWhitespace()
                arr.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw error("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw error("truncated \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A")) + 10
                default: throw error("invalid \\u escape")
                }
                v = v << 4 | d
                i += 1
            }
            return v
        }

        mutating func parseString() throws -> String {
            i += 1  // opening quote
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw error("control character in string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // High surrogate: must be followed by \uDC00-\uDFFF.
                        if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
                default: throw error("invalid escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = i
            var isFloat = false
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count else { throw error("invalid number") }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[i]) {
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            } else {
                throw error("invalid number")
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                isFloat = true
                i += 1
                guard i < bytes.count, isDigit(bytes[i]) else { throw error("invalid fraction") }
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                isFloat = true
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard i < bytes.count, isDigit(bytes[i]) else { throw error("invalid exponent") }
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isFloat, let v = Int64(text) { return .int(v) }
            guard let d = Double(text) else { throw error("invalid number") }
            return .double(d)
        }

        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    }
}
