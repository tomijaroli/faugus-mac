import Foundation

/// One executable of Discord's "detectable applications" list.
public struct DiscordDetectableEntry: Equatable, Sendable {
    /// Lowercased, forward slashes, without Discord's leading `>` marker.
    public var executableName: String
    public var applicationID: String
    public var applicationName: String
    public var isLauncher: Bool

    public init(executableName: String, applicationID: String, applicationName: String, isLauncher: Bool) {
        self.executableName = executableName
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.isLauncher = isLauncher
    }
}

/// Lowercase basename of each Windows/Linux executable name -> its entries (upstream's index).
public struct DiscordDetectableIndex: Equatable, Sendable {
    public private(set) var entriesByBasename: [String: [DiscordDetectableEntry]]

    public init(entriesByBasename: [String: [DiscordDetectableEntry]] = [:]) {
        self.entriesByBasename = entriesByBasename
    }

    public var isEmpty: Bool {
        entriesByBasename.isEmpty
    }

    public func entries(forBasename basename: String) -> [DiscordDetectableEntry] {
        entriesByBasename[basename] ?? []
    }

    /// Normalises a Discord executable name: lowercase, no leading `>`, backslashes to `/`.
    static func normalizedExecutableName(_ name: String) -> String {
        var normalized = name.lowercased()
        while normalized.hasPrefix(">") {
            normalized.removeFirst()
        }
        return normalized.replacingOccurrences(of: "\\", with: "/")
    }

    static func basename(of executableName: String) -> String {
        executableName.components(separatedBy: "/").last ?? executableName
    }

    /// Builds the index from the `/applications/detectable` response; `nil` when it is not an array.
    public init?(applicationsJSON: JSONValue) {
        guard let applications = applicationsJSON.arrayValue else { return nil }
        var index: [String: [DiscordDetectableEntry]] = [:]
        for application in applications.compactMap(\.objectValue) {
            guard let applicationID = application["id"]?.stringValue,
                  let applicationName = application["name"]?.stringValue
            else { continue }
            for executable in (application["executables"]?.arrayValue ?? []).compactMap(\.objectValue) {
                guard let platform = executable["os"]?.stringValue, platform == "win32" || platform == "linux",
                      let rawName = executable["name"]?.stringValue
                else { continue }
                let name = Self.normalizedExecutableName(rawName)
                index[Self.basename(of: name), default: []].append(DiscordDetectableEntry(
                    executableName: name, applicationID: applicationID, applicationName: applicationName,
                    isLauncher: executable["is_launcher"]?.isTruthy ?? false
                ))
            }
        }
        entriesByBasename = index
    }

    /// Reads the cache file's format (upstream-compatible):
    /// `{basename: [[name, application id, application name, is launcher], ...]}`.
    public init?(cacheJSON: JSONValue) {
        guard let object = cacheJSON.objectValue else { return nil }
        var index: [String: [DiscordDetectableEntry]] = [:]
        for (basename, value) in object.pairs {
            for row in (value.arrayValue ?? []).compactMap(\.arrayValue) {
                guard row.count >= 4, let name = row[0].stringValue, let applicationID = row[1].stringValue,
                      let applicationName = row[2].stringValue
                else { continue }
                index[basename, default: []].append(DiscordDetectableEntry(
                    executableName: Self.normalizedExecutableName(name), applicationID: applicationID,
                    applicationName: applicationName, isLauncher: row[3].isTruthy
                ))
            }
        }
        entriesByBasename = index
    }

    public var cacheJSON: JSONValue {
        var object = JSONObject()
        for basename in entriesByBasename.keys.sorted() {
            object[basename] = .array((entriesByBasename[basename] ?? []).map { entry in
                .array([
                    .string(entry.executableName), .string(entry.applicationID),
                    .string(entry.applicationName), .bool(entry.isLauncher),
                ])
            })
        }
        return .object(object)
    }
}

public typealias DiscordHTTPFetch = @Sendable (URLRequest) async throws -> Data

/// `discord_load_detectable`: the cached index while it is under 7 days old, else a fresh download
/// (cached again), else a stale cache, else an empty index.
public struct DiscordDetectableLoader: Sendable {
    public static let detectableURLString = "https://discord.com/api/v10/applications/detectable"
    public static let userAgent = "Faugus-Launcher"
    public static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let requestTimeout: TimeInterval = 15

    public static let liveFetch: DiscordHTTPFetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200 ..< 300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public let cachePath: String
    private let fetch: DiscordHTTPFetch
    private let now: @Sendable () -> Date

    public init(
        paths: FaugusPaths,
        fetch: @escaping DiscordHTTPFetch = DiscordDetectableLoader.liveFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        cachePath = paths.dataDirectory + "/discord-detectable.json"
        self.fetch = fetch
        self.now = now
    }

    public func load() async -> DiscordDetectableIndex {
        if let modified = cacheModificationDate(), now().timeIntervalSince(modified) < Self.cacheLifetime,
           let cached = readCache()
        {
            return cached
        }
        do {
            guard let url = URL(string: Self.detectableURLString) else { throw URLError(.badURL) }
            var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let data = try await fetch(request)
            guard let index = try DiscordDetectableIndex(applicationsJSON: JSONParser.parse(data)) else {
                throw URLError(.cannotParseResponse)
            }
            try? JSONFile.atomicWrite(JSONWriter.serialize(index.cacheJSON, indent: 0), to: cachePath)
            return index
        } catch {
            return readCache() ?? DiscordDetectableIndex()
        }
    }

    private func cacheModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath)
        return attributes?[.modificationDate] as? Date
    }

    private func readCache() -> DiscordDetectableIndex? {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let json = try? JSONParser.parse(data)
        else { return nil }
        return DiscordDetectableIndex(cacheJSON: json)
    }
}
