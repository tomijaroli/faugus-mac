import Foundation

/// Natural ordering for runner versions such as `11.6_1`, `11.7`, `11.21`.
public struct VersionKey: Comparable, Hashable, Sendable {
    enum Part: Hashable, Sendable {
        case number(Int)
        case text(String)
    }

    let parts: [Part]

    public init(_ string: String) {
        var parts: [Part] = []
        var digits = ""
        var text = ""
        func flushDigits() {
            if !digits.isEmpty {
                parts.append(.number(Int(digits) ?? 0))
                digits = ""
            }
        }
        func flushText() {
            if !text.isEmpty {
                parts.append(.text(text.lowercased()))
                text = ""
            }
        }
        for character in string {
            if character.isASCII, character.isNumber {
                flushText()
                digits.append(character)
            } else if character.isLetter {
                flushDigits()
                text.append(character)
            } else {
                flushDigits()
                flushText() // separators: . _ - space
            }
        }
        flushDigits()
        flushText()
        self.parts = parts
    }

    public static func < (lhs: VersionKey, rhs: VersionKey) -> Bool {
        for (leftPart, rightPart) in zip(lhs.parts, rhs.parts) where leftPart != rightPart {
            switch (leftPart, rightPart) {
            case let (.number(x), .number(y)): return x < y
            case let (.text(x), .text(y)): return x < y
            case (.number, .text): return false // numbers sort after text (11.0 > 11.rc1)
            case (.text, .number): return true
            }
        }
        if lhs.parts.count == rhs.parts.count {
            return false
        }
        // `11.0-rc1` is older than `11.0`; `11.0_1` is newer than `11.0`.
        let (shorter, longer, lhsIsShorter) =
            lhs.parts.count < rhs.parts.count ? (lhs, rhs, true) : (rhs, lhs, false)
        if case .text = longer.parts[shorter.parts.count] {
            return !lhsIsShorter
        }
        return lhsIsShorter
    }
}
