import Foundation

/// `categories.json`: a sorted list of category names.
public struct CategoryStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) { self.paths = paths }

    /// `_get_current_categories`: stripped, non-empty strings.
    public func load() -> [String] {
        guard case .array(let a) = JSONFile.load(paths.categoriesFile, default: .array([])) else { return [] }
        return a.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
        var cats = load()
        if name.isEmpty { throw Failure.emptyName }
        if reserved.contains(name) { throw Failure.reserved }
        if cats.contains(name) { throw Failure.duplicate }
        cats.append(name)
        let sorted = Self.caseInsensitiveSorted(cats)
        try save(sorted)
        return sorted
    }

    /// Edit: renames the category and rewrites every game that carries it.
    @discardableResult
    public func rename(_ old: String, to rawNew: String, reserved: [String]) throws -> [String] {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        var cats = load()
        if new.isEmpty || new == old { throw Failure.emptyName }
        if reserved.contains(new) { throw Failure.reserved }
        if cats.contains(new) { throw Failure.duplicate }
        guard let i = cats.firstIndex(of: old) else { throw Failure.missing }
        cats[i] = new
        let sorted = Self.caseInsensitiveSorted(cats)
        try save(sorted)
        try CategoryAssignments(paths: paths).renameEverywhere(old, to: new)
        return sorted
    }

    /// Remove: drops the category from the list and from every game.
    @discardableResult
    public func remove(_ name: String) throws -> [String] {
        var cats = load()
        guard let i = cats.firstIndex(of: name) else { throw Failure.missing }
        cats.remove(at: i)
        try save(cats)
        try CategoryAssignments(paths: paths).removeEverywhere(name)
        return cats
    }
}

/// Edits the `category` field in `games.json` directly, like upstream (no snapshot is taken,
/// and every other field of every entry is untouched).
public struct CategoryAssignments: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) { self.paths = paths }

    private func mutate(_ body: (inout JSONObject) -> Bool) throws {
        guard case .array(var entries) = try JSONFile.loadOrThrow(paths.gamesJSON) else { return }
        var changed = false
        for i in entries.indices {
            guard case .object(var o) = entries[i] else { continue }
            if body(&o) { entries[i] = .object(o); changed = true }
        }
        if changed { try JSONFile.save(.array(entries), to: paths.gamesJSON) }
    }

    private static func names(_ v: JSONValue?) -> [String]? {
        switch v {
        case .string(let s)?: return [s]
        case .array(let a)?: return a.compactMap(\.stringValue)
        default: return nil
        }
    }

    /// The context-menu Category item: "None" clears, any other name toggles. An empty result
    /// removes the key (so a later full save writes `false` again).
    public func toggle(gameID: String, category: String, noneLabel: String = "None") throws {
        try mutate { o in
            guard o["gameid"]?.stringValue == gameID else { return false }
            var cats = Self.names(o["category"]) ?? []
            if category == noneLabel {
                cats = []
            } else if let i = cats.firstIndex(of: category) {
                cats.remove(at: i)
            } else {
                cats.append(category)
            }
            o["category"] = cats.isEmpty ? nil : .array(cats.map { .string($0) })
            return true
        }
    }

    /// `_update_games_category`: a lone string becomes `[new]`; lists are mapped and de-duplicated.
    public func renameEverywhere(_ old: String, to new: String) throws {
        try mutate { o in
            switch o["category"] {
            case .string(let s)? where s == old:
                o["category"] = .array([.string(new)])
                return true
            case .array(let a)? where a.contains(.string(old)):
                var seen = Set<String>()
                let mapped = a.compactMap(\.stringValue).map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
                o["category"] = .array(mapped.map { .string($0) })
                return true
            default: return false
            }
        }
    }

    /// `_remove_games_category`.
    public func removeEverywhere(_ name: String) throws {
        try mutate { o in
            switch o["category"] {
            case .string(let s)? where s == name:
                o["category"] = nil
                return true
            case .array(let a)? where a.contains(.string(name)):
                let rest = a.filter { $0 != .string(name) }
                o["category"] = rest.isEmpty ? nil : .array(rest)
                return true
            default: return false
            }
        }
    }
}

/// `custom-order.json`: `{gameid: position}`.
public struct CustomOrderStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) { self.paths = paths }

    public func load() -> [String: Int] {
        guard case .object(let o) = JSONFile.load(paths.customOrderFile, default: .object(JSONObject())) else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in o.pairs {
            switch v {
            case .int(let i): out[k] = Int(i)
            case .double(let d): out[k] = Int(d)
            default: break
            }
        }
        return out
    }

    public func save(_ order: [String: Int]) throws {
        var o = JSONObject()
        for (k, v) in order.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) { o[k] = .int(Int64(v)) }
        try JSONFile.save(.object(o), to: paths.customOrderFile)
    }

    /// `move_custom_order`: drag `source` onto `target`. Returns the new order, or `nil` when
    /// nothing moved.
    public static func move(ordered: [String], source: String, target: String) -> [String: Int]? {
        guard let src = ordered.firstIndex(of: source), let dst = ordered.firstIndex(of: target), src != dst else { return nil }
        var list = ordered
        list.remove(at: src)
        list.insert(source, at: dst)
        var out: [String: Int] = [:]
        for (i, id) in list.enumerated() { out[id] = i }
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
    public init(paths: FaugusPaths) { self.paths = paths }

    private func loadAll() -> JSONObject {
        if case .object(let o) = JSONFile.load(paths.recentRunFilesFile, default: .object(JSONObject())) { return o }
        return JSONObject()
    }

    /// Existing files only (upstream drops entries whose file is gone when building the menu).
    public func files(gameID: String) -> [String] {
        guard case .array(let a)? = loadAll()[gameID] else { return [] }
        return a.compactMap(\.stringValue).filter { FileManager.default.fileExists(atPath: $0) }
    }

    public func record(gameID: String, file: String) throws {
        var all = loadAll()
        var files: [String] = []
        if case .array(let a)? = all[gameID] { files = a.compactMap(\.stringValue) }
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
