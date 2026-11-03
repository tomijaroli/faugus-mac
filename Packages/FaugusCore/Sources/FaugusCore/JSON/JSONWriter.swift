import Foundation

/// Serializes exactly like Python's `json.dump(data, f, indent=4, ensure_ascii=False)`:
/// 4-space indent, `", "`-free item separators (newline instead), `": "` key separator, empty
/// containers as `[]` / `{}`, no trailing newline, non-ASCII written as-is.
public enum JSONWriter {
    public static func serialize(_ value: JSONValue, indent: Int = 4) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(1024)
        write(value, level: 0, indent: indent, into: &out)
        return Data(out)
    }

    public static func string(_ value: JSONValue, indent: Int = 4) -> String {
        String(decoding: serialize(value, indent: indent), as: UTF8.self)
    }

    private static func write(_ v: JSONValue, level: Int, indent: Int, into out: inout [UInt8]) {
        switch v {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i): out.append(contentsOf: String(i).utf8)
        case .double(let d): out.append(contentsOf: formatDouble(d).utf8)
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            if a.isEmpty { out.append(contentsOf: "[]".utf8); return }
            out.append(UInt8(ascii: "["))
            for (n, item) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1, indent, &out)
                write(item, level: level + 1, indent: indent, into: &out)
            }
            newline(level, indent, &out)
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            if o.isEmpty { out.append(contentsOf: "{}".utf8); return }
            out.append(UInt8(ascii: "{"))
            for (n, pair) in o.pairs.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1, indent, &out)
                writeString(pair.key, into: &out)
                out.append(contentsOf: ": ".utf8)
                write(pair.value, level: level + 1, indent: indent, into: &out)
            }
            newline(level, indent, &out)
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func newline(_ level: Int, _ indent: Int, _ out: inout [UInt8]) {
        out.append(0x0A)
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: level * indent))
    }

    private static func formatDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        return "\(d)"
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(contentsOf: "\\\"".utf8)
            case 0x5C: out.append(contentsOf: "\\\\".utf8)
            case 0x08: out.append(contentsOf: "\\b".utf8)
            case 0x0C: out.append(contentsOf: "\\f".utf8)
            case 0x0A: out.append(contentsOf: "\\n".utf8)
            case 0x0D: out.append(contentsOf: "\\r".utf8)
            case 0x09: out.append(contentsOf: "\\t".utf8)
            case 0x00..<0x20:
                let hex = String(b, radix: 16)
                out.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).utf8)
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
