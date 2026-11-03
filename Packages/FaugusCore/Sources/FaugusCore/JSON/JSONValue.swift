import Foundation

/// An insertion-ordered JSON object. Python's `json` module preserves key order, and upstream
/// Faugus files are re-saved wholesale, so the port must keep key order to avoid noisy diffs
/// and to stay byte-compatible with files written by the Linux version.
public struct JSONObject: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements {
            self[k] = v
        }
    }

    public init(pairs: [(String, JSONValue)]) {
        for (k, v) in pairs {
            self[k] = v
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
        if case let .string(s) = self {
            return s
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self {
            return b
        }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case let .int(i): i
        case let .double(d) where d == d.rounded() && abs(d) < 9e18: Int64(d)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .double(d): d
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self {
            return a
        }
        return nil
    }

    public var objectValue: JSONObject? {
        if case let .object(o) = self {
            return o
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
        case let .bool(b): b
        case let .int(i): i != 0
        case let .double(d): d != 0
        case let .string(s): !s.isEmpty
        case let .array(a): !a.isEmpty
        case let .object(o): !o.isEmpty
        }
    }
}
