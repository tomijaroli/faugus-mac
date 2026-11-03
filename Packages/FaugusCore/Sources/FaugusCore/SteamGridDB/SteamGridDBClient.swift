import Foundation

/// One image offered by SteamGridDB: the full-size `url` and a smaller `thumb` (the `url` when
/// the API gives no thumbnail).
public struct SteamGridDBCandidate: Equatable, Sendable {
    public let url: String
    public let thumb: String

    public init(url: String, thumb: String) {
        self.url = url
        self.thumb = thumb
    }
}

/// `fetch_steamgriddb_candidates` result. `gameID` is the SteamGridDB game id that was used
/// (nil when the lookup went through a Steam app id, or when the search found nothing).
public struct SteamGridDBCandidates: Equatable, Sendable {
    public var gameID: Int?
    public var grids: [SteamGridDBCandidate] = []
    public var heroes: [SteamGridDBCandidate] = []
    public var icons: [SteamGridDBCandidate] = []

    public init(
        gameID: Int? = nil,
        grids: [SteamGridDBCandidate] = [],
        heroes: [SteamGridDBCandidate] = [],
        icons: [SteamGridDBCandidate] = []
    ) {
        self.gameID = gameID
        self.grids = grids
        self.heroes = heroes
        self.icons = icons
    }
}

/// Port of `get_steamgriddb_session`, `fetch_steamgriddb_autocomplete` and
/// `fetch_steamgriddb_candidates`. Every failure is swallowed into an empty result, as upstream.
public struct SteamGridDBClient: Sendable {
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    public static let apiBaseURL = "https://www.steamgriddb.com/api/v2"
    public static let apiTimeout: TimeInterval = 10
    public static let downloadTimeout: TimeInterval = 15
    /// `Retry(total=3)`: three retries after the first attempt.
    public static let maximumRetries = 3
    public static let backoffFactor: TimeInterval = 0.3
    /// `status_forcelist`.
    public static let retriedStatusCodes: Set = [429, 500, 502, 503, 504]
    public static let defaultAutocompleteLimit = 10
    public static let defaultCandidateLimit = 12
    public static let gridDimensions = "600x900"

    public static let defaultSleeper: Sleeper = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    private let apiKey: String
    private let transport: any SteamGridDBTransport
    private let sleeper: Sleeper

    public init(
        apiKey: String,
        transport: any SteamGridDBTransport = URLSessionSteamGridDBTransport(),
        sleeper: @escaping Sleeper = SteamGridDBClient.defaultSleeper
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.sleeper = sleeper
    }

    // MARK: Search

    /// `fetch_steamgriddb_autocomplete`: up to `limit` games matching `term`, `[]` on any error.
    public func autocomplete(term: String, limit: Int = SteamGridDBClient.defaultAutocompleteLimit)
        async -> [(id: Int, name: String)]
    {
        guard let items = try? await dataItems(path: "/search/autocomplete/\(Self.quote(term))") else { return [] }
        return items.prefix(max(limit, 0)).compactMap { item in
            guard let identifier = item["id"] as? Int,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            return (id: identifier, name: name)
        }
    }

    /// `fetch_steamgriddb_candidates`. A Steam app id looks images up by `steam`; otherwise the
    /// `game` id is the supplied one or the first autocomplete hit. The three image endpoints are
    /// requested concurrently and each failure leaves just its own list empty.
    public func candidates(
        gameName: String,
        limit: Int = SteamGridDBClient.defaultCandidateLimit,
        gameID: Int? = nil,
        steamAppID: Int? = nil
    ) async -> SteamGridDBCandidates {
        var result = SteamGridDBCandidates()
        let identifierType: String
        let lookupID: Int
        if let steamAppID {
            identifierType = "steam"
            lookupID = steamAppID
        } else {
            var resolvedGameID = gameID
            if resolvedGameID == nil {
                guard let firstMatch = await autocomplete(term: gameName, limit: 1).first else { return result }
                resolvedGameID = firstMatch.id
            }
            guard let resolvedGameID else { return result }
            identifierType = "game"
            lookupID = resolvedGameID
            result.gameID = resolvedGameID
        }

        async let grids = candidateList(
            path: "/grids/\(identifierType)/\(lookupID)",
            query: "dimensions=\(Self.gridDimensions)",
            limit: limit
        )
        async let heroes = candidateList(path: "/heroes/\(identifierType)/\(lookupID)", query: nil, limit: limit)
        async let icons = candidateList(path: "/icons/\(identifierType)/\(lookupID)", query: nil, limit: limit)
        result.grids = await grids
        result.heroes = await heroes
        result.icons = await icons
        return result
    }

    private func candidateList(path: String, query: String?, limit: Int) async -> [SteamGridDBCandidate] {
        guard let items = try? await dataItems(path: path, query: query) else { return [] }
        return items.prefix(max(limit, 0)).compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            let thumb = (item["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            return SteamGridDBCandidate(url: url, thumb: thumb)
        }
    }

    /// The `data` array of an API answer; throws for transport, status and JSON errors.
    private func dataItems(path: String, query: String? = nil) async throws -> [[String: Any]] {
        let query = query.map { "?\($0)" } ?? ""
        let (body, _) = try await fetch(
            urlString: Self.apiBaseURL + path + query, authorized: true, timeout: Self.apiTimeout
        )
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        return root["data"] as? [[String: Any]] ?? []
    }

    // MARK: Images

    /// `verified_content` + validation: downloads `urlString` (no API key is sent), rejects a
    /// body whose size differs from `Content-Length`, and accepts only data that decodes as an image.
    public func downloadImage(from urlString: String) async throws -> Data {
        let (body, response) = try await fetch(
            urlString: urlString, authorized: false, timeout: Self.downloadTimeout
        )
        if let expectedText = response.value(forHTTPHeaderField: "Content-Length"),
           let expectedBytes = Int(expectedText.trimmingCharacters(in: .whitespaces)),
           Self.isTransferEncodingIdentity(response),
           body.count != expectedBytes
        {
            throw SteamGridDBError.truncatedDownload(expectedBytes: expectedBytes, actualBytes: body.count)
        }
        guard body.count <= GameArtwork.maxDownloadBytes else { throw SteamGridDBError.tooLarge }
        guard ImageTools.isValid(body) else { throw SteamGridDBError.notAnImage }
        return body
    }

    /// `URLSession` hands back decompressed bodies, so `Content-Length` of a compressed answer
    /// says nothing about the size of `body`.
    private static func isTransferEncodingIdentity(_ response: HTTPURLResponse) -> Bool {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
        return encoding.isEmpty || encoding == "identity"
    }

    // MARK: Requests

    /// Python's `urllib.parse.quote`: everything but ASCII letters, digits and `_.-~/` is
    /// percent-encoded as UTF-8.
    static func quote(_ text: String) -> String {
        var allowedCharacters = CharacterSet()
        allowedCharacters.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        allowedCharacters.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        allowedCharacters.insert(charactersIn: "0123456789_.-~/")
        return text.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? text
    }

    /// A GET with the session's retry policy (3 retries, `0.3 * 2^n` s apart, on 429/500/502/503/504
    /// and on connection errors). A non-2xx answer after the last attempt throws `badStatus`.
    private func fetch(urlString: String, authorized: Bool, timeout: TimeInterval) async throws
        -> (Data, HTTPURLResponse)
    {
        guard let url = URL(string: urlString) else { throw SteamGridDBError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if authorized {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var retryNumber = 0
        while true {
            try Task.checkCancellation()
            do {
                let (body, response) = try await transport.data(for: request)
                if Self.retriedStatusCodes.contains(response.statusCode), retryNumber < Self.maximumRetries {
                    await sleeper(Self.backoffFactor * pow(2, Double(retryNumber)))
                    retryNumber += 1
                    continue
                }
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw SteamGridDBError.badStatus(response.statusCode)
                }
                return (body, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SteamGridDBError {
                throw error
            } catch {
                guard retryNumber < Self.maximumRetries else { throw error }
                await sleeper(Self.backoffFactor * pow(2, Double(retryNumber)))
                retryNumber += 1
            }
        }
    }
}
