import Foundation

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String {
        "JSON parse error at byte \(offset): \(message)"
    }
}

/// A small, strict, order-preserving JSON parser (RFC 8259, plus Python's `NaN`/`Infinity`
/// tokens are rejected, which is fine: upstream never writes them).
public enum JSONParser {
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipBOM()
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        if !parser.atEnd {
            throw parser.error("unexpected trailing data")
        }
        return value
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        static let maxDepth = 512

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var atEnd: Bool {
            position >= bytes.count
        }

        func error(_ message: String) -> JSONParseError {
            JSONParseError(message: message, offset: position)
        }

        mutating func skipBOM() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                position = 3
            }
        }

        mutating func skipWhitespace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < Parser.maxDepth else { throw error("nesting too deep") }
            guard position < bytes.count else { throw error("unexpected end of input") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return try .string(parseString())
            case UInt8(ascii: "t"): try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"): try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"): try expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try parseNumber()
            default: throw error("unexpected character")
            }
        }

        mutating func expect(_ literal: String) throws {
            let literalBytes = Array(literal.utf8)
            guard position + literalBytes.count <= bytes.count,
                  Array(bytes[position ..< (position + literalBytes.count)]) == literalBytes
            else {
                throw error("invalid literal")
            }
            position += literalBytes.count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            position += 1
            var object = JSONObject()
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                    throw error("expected string key")
                }
                let key = try parseString()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
                position += 1
                skipWhitespace()
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated object") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                    continue
                }
                if bytes[position] == UInt8(ascii: "}") {
                    position += 1
                    return .object(object)
                }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            position += 1
            var array: [JSONValue] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(array)
            }
            while true {
                skipWhitespace()
                try array.append(parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated array") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                    continue
                }
                if bytes[position] == UInt8(ascii: "]") {
                    position += 1
                    return .array(array)
                }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw error("truncated \\u escape") }
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                let byte = bytes[position]
                let digitValue: UInt32
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): digitValue = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): digitValue = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A") ... UInt8(ascii: "F"): digitValue = UInt32(byte - UInt8(ascii: "A")) + 10
                default: throw error("invalid \\u escape")
                }
                value = value << 4 | digitValue
                position += 1
            }
            return value
        }

        mutating func parseString() throws -> String {
            position += 1 // opening quote
            var decodedBytes = [UInt8]()
            while true {
                guard position < bytes.count else { throw error("unterminated string") }
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    position += 1
                    break
                }
                if byte < 0x20 {
                    throw error("control character in string")
                }
                if byte != UInt8(ascii: "\\") {
                    decodedBytes.append(byte)
                    position += 1
                    continue
                }
                position += 1
                guard position < bytes.count else { throw error("unterminated escape") }
                let escapeByte = bytes[position]
                position += 1
                switch escapeByte {
                case UInt8(ascii: "\""): decodedBytes.append(0x22)
                case UInt8(ascii: "\\"): decodedBytes.append(0x5C)
                case UInt8(ascii: "/"): decodedBytes.append(0x2F)
                case UInt8(ascii: "b"): decodedBytes.append(0x08)
                case UInt8(ascii: "f"): decodedBytes.append(0x0C)
                case UInt8(ascii: "n"): decodedBytes.append(0x0A)
                case UInt8(ascii: "r"): decodedBytes.append(0x0D)
                case UInt8(ascii: "t"): decodedBytes.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800 ... 0xDBFF).contains(scalar) {
                        // High surrogate: must be followed by \uDC00-\uDFFF.
                        if position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                           bytes[position + 1] == UInt8(ascii: "u")
                        {
                            position += 2
                            let low = try parseHex4()
                            guard (0xDC00 ... 0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00 ... 0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    decodedBytes.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
                default: throw error("invalid escape")
                }
            }
            return String(decoding: decodedBytes, as: UTF8.self)
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = position
            var isFloat = false
            if bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard position < bytes.count else { throw error("invalid number") }
            if bytes[position] == UInt8(ascii: "0") {
                position += 1
            } else if (UInt8(ascii: "1") ... UInt8(ascii: "9")).contains(bytes[position]) {
                while position < bytes.count, isDigit(bytes[position]) {
                    position += 1
                }
            } else {
                throw error("invalid number")
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                isFloat = true
                position += 1
                guard position < bytes.count, isDigit(bytes[position]) else { throw error("invalid fraction") }
                while position < bytes.count, isDigit(bytes[position]) {
                    position += 1
                }
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
                isFloat = true
                position += 1
                if position < bytes.count,
                   bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-")
                {
                    position += 1
                }
                guard position < bytes.count, isDigit(bytes[position]) else { throw error("invalid exponent") }
                while position < bytes.count, isDigit(bytes[position]) {
                    position += 1
                }
            }
            let text = String(decoding: bytes[start ..< position], as: UTF8.self)
            if !isFloat, let integer = Int64(text) {
                return .int(integer)
            }
            guard let number = Double(text) else { throw error("invalid number") }
            return .double(number)
        }

        func isDigit(_ byte: UInt8) -> Bool {
            byte >= 0x30 && byte <= 0x39
        }
    }
}
