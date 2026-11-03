import Foundation

/// `categories.json`: a sorted list of category names.
public struct CategoryStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    /// `_get_current_categories`: stripped, non-empty strings.
    public func load() -> [String] {
        guard case let .array(items) = JSONFile.load(paths.categoriesFile, default: .array([])) else { return [] }
        return items.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func save(_ names: [String]) throws {
        try JSONFile.save(.array(names.map { .string($0) }), to: paths.categoriesFile)
    }

    private static func caseInsensitiveSorted(_ names: [String]) -> [String] {
        names.sorted { $0.lowercased() < $1.lowercased() }
    }

    public enum Failure: Error, Equatable { case emptyName, reserved, duplicate, missing }

    /// "Manage categories" Add. Reserved names are the translated None / All / Uncategorized.
    @discardableResult
    public func add(_ rawName: String, reserved: [String]) throws -> [String] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var categories = load()
        if name.isEmpty {
            throw Failure.emptyName
        }
        if reserved.contains(name) {
            throw Failure.reserved
        }
        if categories.contains(name) {
            throw Failure.duplicate
        }
        categories.append(name)
        let sorted = Self.caseInsensitiveSorted(categories)
        try save(sorted)
        return sorted
    }

    /// Edit: renames the category and rewrites every game that carries it.
    @discardableResult
    public func rename(_ old: String, to rawNew: String, reserved: [String]) throws -> [String] {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        var categories = load()
        if new.isEmpty || new == old {
            throw Failure.emptyName
        }
        if reserved.contains(new) {
            throw Failure.reserved
        }
        if categories.contains(new) {
            throw Failure.duplicate
        }
        guard let index = categories.firstIndex(of: old) else { throw Failure.missing }
        categories[index] = new
        let sorted = Self.caseInsensitiveSorted(categories)
        try save(sorted)
        try CategoryAssignments(paths: paths).renameEverywhere(old, to: new)
        return sorted
    }

    /// Remove: drops the category from the list and from every game.
    @discardableResult
    public func remove(_ name: String) throws -> [String] {
        var categories = load()
        guard let index = categories.firstIndex(of: name) else { throw Failure.missing }
        categories.remove(at: index)
        try save(categories)
        try CategoryAssignments(paths: paths).removeEverywhere(name)
        return categories
    }
}

/// Edits the `category` field in `games.json` directly, like upstream (no snapshot is taken,
/// and every other field of every entry is untouched).
public struct CategoryAssignments: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    private func mutate(_ body: (inout JSONObject) -> Bool) throws {
        guard case var .array(entries) = try JSONFile.loadOrThrow(paths.gamesJSON) else { return }
        var changed = false
        for index in entries.indices {
            guard case var .object(object) = entries[index] else { continue }
            if body(&object) {
                entries[index] = .object(object)
                changed = true
            }
        }
        if changed {
            try JSONFile.save(.array(entries), to: paths.gamesJSON)
        }
    }

    private static func names(_ value: JSONValue?) -> [String]? {
        switch value {
        case let .string(text)?: [text]
        case let .array(items)?: items.compactMap(\.stringValue)
        default: nil
        }
    }

    /// The context-menu Category item: "None" clears, any other name toggles. An empty result
    /// removes the key (so a later full save writes `false` again).
    public func toggle(gameID: String, category: String, noneLabel: String = "None") throws {
        try mutate { object in
            guard object["gameid"]?.stringValue == gameID else { return false }
            var categories = Self.names(object["category"]) ?? []
            if category == noneLabel {
                categories = []
            } else if let index = categories.firstIndex(of: category) {
                categories.remove(at: index)
            } else {
                categories.append(category)
            }
            object["category"] = categories.isEmpty ? nil : .array(categories.map { .string($0) })
            return true
        }
    }

    /// `_update_games_category`: a lone string becomes `[new]`; lists are mapped and de-duplicated.
    public func renameEverywhere(_ old: String, to new: String) throws {
        try mutate { object in
            switch object["category"] {
            case let .string(text)? where text == old:
                object["category"] = .array([.string(new)])
                return true
            case let .array(items)? where items.contains(.string(old)):
                var seen = Set<String>()
                let mapped = items.compactMap(\.stringValue).map { $0 == old ? new : $0 }
                    .filter { seen.insert($0).inserted }
                object["category"] = .array(mapped.map { .string($0) })
                return true
            default: return false
            }
        }
    }

    /// `_remove_games_category`.
    public func removeEverywhere(_ name: String) throws {
        try mutate { object in
            switch object["category"] {
            case let .string(text)? where text == name:
                object["category"] = nil
                return true
            case let .array(items)? where items.contains(.string(name)):
                let rest = items.filter { $0 != .string(name) }
                object["category"] = rest.isEmpty ? nil : .array(rest)
                return true
            default: return false
            }
        }
    }
}

/// `custom-order.json`: `{gameid: position}`.
public struct CustomOrderStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func load() -> [String: Int] {
        guard case let .object(object) = JSONFile.load(paths.customOrderFile, default: .object(JSONObject()))
        else { return [:] }
        var out: [String: Int] = [:]
        for (key, value) in object.pairs {
            switch value {
            case let .int(integer): out[key] = Int(integer)
            case let .double(double): out[key] = Int(double)
            default: break
            }
        }
        return out
    }

    public func save(_ order: [String: Int]) throws {
        var object = JSONObject()
        for (key, position) in order.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            object[key] = .int(Int64(position))
        }
        try JSONFile.save(.object(object), to: paths.customOrderFile)
    }

    /// `move_custom_order`: drag `source` onto `target`. Returns the new order, or `nil` when
    /// nothing moved.
    public static func move(ordered: [String], source: String, target: String) -> [String: Int]? {
        guard let sourceIndex = ordered.firstIndex(of: source), let targetIndex = ordered.firstIndex(of: target),
              sourceIndex != targetIndex else { return nil }
        var list = ordered
        list.remove(at: sourceIndex)
        list.insert(source, at: targetIndex)
        var out: [String: Int] = [:]
        for (position, id) in list.enumerated() {
            out[id] = position
        }
        return out
    }

    /// `remove_latest_and_order`: forget a deleted game.
    public func remove(gameID: String) throws {
        var order = load()
        guard order.removeValue(forKey: gameID) != nil else { return }
        try save(order)
    }
}

/// `recent-run-files.json`: `{gameid: [file, ...]}` newest first, at most 5.
public struct RecentRunFiles: Sendable {
    public static let limit = 5
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    private func loadAll() -> JSONObject {
        if case let .object(object) = JSONFile.load(paths.recentRunFilesFile, default: .object(JSONObject())) {
            return object
        }
        return JSONObject()
    }

    /// Existing files only (upstream drops entries whose file is gone when building the menu).
    public func files(gameID: String) -> [String] {
        guard case let .array(items)? = loadAll()[gameID] else { return [] }
        return items.compactMap(\.stringValue).filter { FileManager.default.fileExists(atPath: $0) }
    }

    public func record(gameID: String, file: String) throws {
        var all = loadAll()
        var files: [String] = []
        if case let .array(items)? = all[gameID] {
            files = items.compactMap(\.stringValue)
        }
        files.removeAll { $0 == file }
        files.insert(file, at: 0)
        all[gameID] = .array(files.prefix(Self.limit).map { .string($0) })
        try JSONFile.save(.object(all), to: paths.recentRunFilesFile)
    }

    public func clear(gameID: String) throws {
        var all = loadAll()
        guard all[gameID] != nil else { return }
        all[gameID] = nil
        try JSONFile.save(.object(all), to: paths.recentRunFilesFile)
    }
}
