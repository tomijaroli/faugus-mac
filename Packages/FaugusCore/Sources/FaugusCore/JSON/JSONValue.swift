import Foundation

/// An insertion-ordered JSON object. Python's `json` module preserves key order, and upstream
/// Faugus files are re-saved wholesale, so the port must keep key order to avoid noisy diffs
/// and to stay byte-compatible with files written by the Linux version.
public struct JSONObject: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements {
            self[key] = value
        }
    }

    public init(pairs: [(String, JSONValue)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public var count: Int {
        keys.count
    }

    public var isEmpty: Bool {
        keys.isEmpty
    }

    public var pairs: [(key: String, value: JSONValue)] {
        keys.map { ($0, storage[$0]!) }
    }

    public func contains(_ key: String) -> Bool {
        storage[key] != nil
    }

    /// Assigning to an existing key keeps its position (same as a Python dict). Assigning
    /// `nil` removes the key.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil {
                    keys.append(key)
                }
                storage[key] = newValue
            } else if storage[key] != nil {
                storage[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }
}

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Convenience

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int64) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(nilLiteral _: ()) {
        self = .null
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(pairs: elements))
    }
}

extension JSONValue {
    public var stringValue: String? {
        if case let .string(string) = self {
            return string
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(bool) = self {
            return bool
        }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case let .int(integer): integer
        case let .double(number) where number == number.rounded() && abs(number) < 9e18: Int64(number)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(integer): Double(integer)
        case let .double(number): number
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(array) = self {
            return array
        }
        return nil
    }

    public var objectValue: JSONObject? {
        if case let .object(object) = self {
            return object
        }
        return nil
    }

    public var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    /// Python truthiness, used where upstream does `if game.hidden:` on loosely-typed JSON.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case let .bool(bool): bool
        case let .int(integer): integer != 0
        case let .double(number): number != 0
        case let .string(string): !string.isEmpty
        case let .array(array): !array.isEmpty
        case let .object(object): !object.isEmpty
        }
    }
}
