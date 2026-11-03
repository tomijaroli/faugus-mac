import CoreGraphics
@testable import FaugusCore
import Foundation
import Testing

private struct FakeAnswer {
    var statusCode = 200
    var body = Data()
    var headers: [String: String] = [:]
}

private struct FakeConnectionFailure: Error {}

/// Answers by URL and records every request; no sockets are involved.
private final class FakeTransport: SteamGridDBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private var answerQueues: [String: [Result<FakeAnswer, Error>]] = [:]
    private var fallbackAnswer = FakeAnswer(statusCode: 404)

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var requestedURLs: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    /// Answers for `url` are consumed in order; the last one repeats.
    func answer(_ urlString: String, _ answers: Result<FakeAnswer, Error>...) {
        lock.lock()
        defer { lock.unlock() }
        answerQueues[urlString] = answers
    }

    func answerJSON(_ urlString: String, data: Any) throws {
        let body = try JSONSerialization.data(withJSONObject: ["success": true, "data": data])
        answer(urlString, .success(FakeAnswer(body: body)))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = nextAnswer(for: request)
        let answer = try result.get()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: answer.statusCode, httpVersion: "HTTP/1.1", headerFields: answer.headers
        ))
        return (answer.body, response)
    }

    private func nextAnswer(for request: URLRequest) -> Result<FakeAnswer, Error> {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        let key = request.url?.absoluteString ?? ""
        guard var queue = answerQueues[key], !queue.isEmpty else { return .success(fallbackAnswer) }
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        answerQueues[key] = queue
        return next
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [TimeInterval] = []

    var durations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDurations
    }

    var sleeper: SteamGridDBClient.Sleeper {
        { [self] seconds in record(seconds) }
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        recordedDurations.append(seconds)
    }
}

private struct PNGFixtureFailure: Error {}

private func makePNG(width: Int, height: Int) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { throw PNGFixtureFailure() }
    context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(), let data = ImageTools.png(image) else { throw PNGFixtureFailure() }
    return data
}

private let base = "https://www.steamgriddb.com/api/v2"

@Suite("SteamGridDB")
struct SteamGridDBTests {
    private func makeClient(
        _ transport: FakeTransport,
        recorder: SleepRecorder = SleepRecorder()
    ) -> SteamGridDBClient {
        SteamGridDBClient(apiKey: "secret-key", transport: transport, sleeper: recorder.sleeper)
    }

    // MARK: URL construction

    @Test func quoteFollowsPythonQuote() {
        #expect(SteamGridDBClient.quote("Half-Life 2: Ep/1 & ñ") == "Half-Life%202%3A%20Ep/1%20%26%20%C3%B1")
        #expect(SteamGridDBClient.quote("a_b.c-d~e") == "a_b.c-d~e")
        #expect(SteamGridDBClient.quote("100%?#") == "100%25%3F%23")
    }

    @Test func autocompleteBuildsAuthorizedRequest() async throws {
        let transport = FakeTransport()
        try transport.answerJSON("\(base)/search/autocomplete/Hades%20II", data: [["id": 7, "name": "Hades II"]])
        let matches = await makeClient(transport).autocomplete(term: "Hades II")
        #expect(matches.map(\.id) == [7])
        #expect(matches.map(\.name) == ["Hades II"])
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "\(base)/search/autocomplete/Hades%20II")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.timeoutInterval == 10)
    }

    @Test func autocompleteHonorsLimitAndSkipsNamelessEntries() async throws {
        let transport = FakeTransport()
        try transport.answerJSON(
            "\(base)/search/autocomplete/game",
            data: [["id": 1, "name": "One"], ["id": 2], ["id": 3, "name": "Three"], ["id": 4, "name": "Four"]]
        )
        let client = makeClient(transport)
        // Upstream slices to `limit` first, then drops entries without a name.
        #expect(await client.autocomplete(term: "game", limit: 3).map(\.id) == [1, 3])
        #expect(await client.autocomplete(term: "game").map(\.id) == [1, 3, 4])
    }

    @Test func autocompleteIsEmptyOnAnyError() async {
        let transport = FakeTransport()
        let client = makeClient(transport)
        // Unknown URL answers 404.
        #expect(await client.autocomplete(term: "x").isEmpty)
        transport.answer("\(base)/search/autocomplete/bad", .success(FakeAnswer(body: Data("not json".utf8))))
        #expect(await client.autocomplete(term: "bad").isEmpty)
        transport.answer("\(base)/search/autocomplete/down", .failure(FakeConnectionFailure()))
        #expect(await client.autocomplete(term: "down").isEmpty)
    }

    @Test func steamAppIDLooksUpBySteamTypeWithoutSearching() async throws {
        let transport = FakeTransport()
        try transport.answerJSON("\(base)/grids/steam/620?dimensions=600x900", data: [["url": "g1", "thumb": "g1t"]])
        try transport.answerJSON("\(base)/heroes/steam/620", data: [["url": "h1", "thumb": "h1t"]])
        try transport.answerJSON("\(base)/icons/steam/620", data: [["url": "i1", "thumb": "i1t"]])
        let result = await makeClient(transport).candidates(gameName: "Portal 2", steamAppID: 620)
        #expect(result.gameID == nil)
        #expect(result.grids == [SteamGridDBCandidate(url: "g1", thumb: "g1t")])
        #expect(result.heroes == [SteamGridDBCandidate(url: "h1", thumb: "h1t")])
        #expect(result.icons == [SteamGridDBCandidate(url: "i1", thumb: "i1t")])
        #expect(Set(transport.requestedURLs) == [
            "\(base)/grids/steam/620?dimensions=600x900",
            "\(base)/heroes/steam/620",
            "\(base)/icons/steam/620",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key" })
    }

    @Test func gameTypeUsesFirstAutocompleteHit() async throws {
        let transport = FakeTransport()
        try transport.answerJSON(
            "\(base)/search/autocomplete/Half-Life%202",
            data: [["id": 42, "name": "Half-Life 2"], ["id": 43, "name": "Other"]]
        )
        try transport.answerJSON("\(base)/grids/game/42?dimensions=600x900", data: [["url": "g"]])
        let result = await makeClient(transport).candidates(gameName: "Half-Life 2")
        #expect(result.gameID == 42)
        #expect(result.grids == [SteamGridDBCandidate(url: "g", thumb: "g")])
        #expect(result.heroes.isEmpty)
        #expect(result.icons.isEmpty)
        #expect(Set(transport.requestedURLs) == [
            "\(base)/search/autocomplete/Half-Life%202",
            "\(base)/grids/game/42?dimensions=600x900",
            "\(base)/heroes/game/42",
            "\(base)/icons/game/42",
        ])
    }

    @Test func suppliedGameIDSkipsTheSearch() async {
        let transport = FakeTransport()
        let result = await makeClient(transport).candidates(gameName: "Anything", gameID: 99)
        #expect(result.gameID == 99)
        #expect(!transport.requestedURLs.contains { $0.contains("autocomplete") })
        #expect(transport.requestedURLs.contains("\(base)/icons/game/99"))
    }

    @Test func noSearchHitReturnsAnEmptyResultAfterOneRequest() async {
        let transport = FakeTransport()
        transport.answer("\(base)/search/autocomplete/Nothing", .success(FakeAnswer(body: Data(#"{"data":[]}"#.utf8))))
        let result = await makeClient(transport).candidates(gameName: "Nothing")
        #expect(result == SteamGridDBCandidates())
        #expect(transport.requestedURLs == ["\(base)/search/autocomplete/Nothing"])
    }

    // MARK: Candidate mapping

    @Test func candidatesMapThumbWithFallbackAndApplyTheLimit() async throws {
        let transport = FakeTransport()
        try transport.answerJSON(
            "\(base)/icons/game/5",
            data: [
                ["url": "a", "thumb": "a-thumb"],
                ["url": "b"],
                ["url": "c", "thumb": ""],
                ["thumb": "orphan"],
                ["url": "d"],
            ]
        )
        let client = makeClient(transport)
        let all = await client.candidates(gameName: "x", limit: 12, gameID: 5)
        #expect(all.icons == [
            SteamGridDBCandidate(url: "a", thumb: "a-thumb"),
            SteamGridDBCandidate(url: "b", thumb: "b"),
            SteamGridDBCandidate(url: "c", thumb: "c"),
            SteamGridDBCandidate(url: "d", thumb: "d"),
        ])
        // The limit applies before entries without a url are dropped.
        let limited = await client.candidates(gameName: "x", limit: 4, gameID: 5)
        #expect(limited.icons.map(\.url) == ["a", "b", "c"])
        #expect(await client.candidates(gameName: "x", limit: 1, gameID: 5).icons.map(\.url) == ["a"])
    }

    @Test func oneFailingEndpointOnlyEmptiesItsOwnList() async throws {
        let transport = FakeTransport()
        try transport.answerJSON("\(base)/grids/game/5?dimensions=600x900", data: [["url": "g"]])
        transport.answer("\(base)/heroes/game/5", .failure(FakeConnectionFailure()))
        transport.answer("\(base)/icons/game/5", .success(FakeAnswer(statusCode: 403)))
        let result = await makeClient(transport).candidates(gameName: "x", gameID: 5)
        #expect(result.grids.map(\.url) == ["g"])
        #expect(result.heroes.isEmpty)
        #expect(result.icons.isEmpty)
        #expect(result.gameID == 5)
    }

    // MARK: Retry policy

    @Test func retriesTransientStatusesWithExponentialBackoff() async throws {
        let transport = FakeTransport()
        let recorder = SleepRecorder()
        let url = "\(base)/search/autocomplete/retry"
        let success = try FakeAnswer(body: JSONSerialization.data(withJSONObject: ["data": [["id": 1, "name": "R"]]]))
        transport.answer(
            url,
            .success(FakeAnswer(statusCode: 429)),
            .success(FakeAnswer(statusCode: 503)),
            .success(success)
        )
        let matches = await makeClient(transport, recorder: recorder).autocomplete(term: "retry")
        #expect(matches.map(\.id) == [1])
        #expect(transport.requestedURLs == [url, url, url])
        #expect(recorder.durations == [0.3, 0.6])
    }

    @Test func givesUpAfterThreeRetries() async {
        let transport = FakeTransport()
        let recorder = SleepRecorder()
        let url = "\(base)/search/autocomplete/down"
        transport.answer(url, .success(FakeAnswer(statusCode: 500)))
        let matches = await makeClient(transport, recorder: recorder).autocomplete(term: "down")
        #expect(matches.isEmpty)
        #expect(transport.requestedURLs.count == 4)
        #expect(recorder.durations == [0.3, 0.6, 1.2])
    }

    @Test func everyStatusInTheForcelistIsRetried() async {
        for statusCode in [429, 500, 502, 503, 504] {
            let transport = FakeTransport()
            let url = "\(base)/search/autocomplete/status"
            transport.answer(
                url,
                .success(FakeAnswer(statusCode: statusCode)),
                .success(FakeAnswer(body: Data(#"{"data":[]}"#.utf8)))
            )
            _ = await makeClient(transport).autocomplete(term: "status")
            #expect(transport.requestedURLs.count == 2, "status \(statusCode)")
        }
    }

    @Test func otherErrorStatusesAreNotRetried() async {
        for statusCode in [400, 401, 403, 404] {
            let transport = FakeTransport()
            let recorder = SleepRecorder()
            transport.answer("\(base)/search/autocomplete/denied", .success(FakeAnswer(statusCode: statusCode)))
            _ = await makeClient(transport, recorder: recorder).autocomplete(term: "denied")
            #expect(transport.requestedURLs.count == 1, "status \(statusCode)")
            #expect(recorder.durations.isEmpty)
        }
    }

    @Test func connectionErrorsAreRetriedToo() async throws {
        let transport = FakeTransport()
        let recorder = SleepRecorder()
        let url = "\(base)/search/autocomplete/flaky"
        let success = try FakeAnswer(body: JSONSerialization.data(withJSONObject: ["data": [["id": 2, "name": "F"]]]))
        transport.answer(url, .failure(FakeConnectionFailure()), .success(success))
        let matches = await makeClient(transport, recorder: recorder).autocomplete(term: "flaky")
        #expect(matches.map(\.id) == [2])
        #expect(recorder.durations == [0.3])
    }

    // MARK: Image download

    @Test func downloadReturnsAValidImageWithoutSendingTheAPIKey() async throws {
        let transport = FakeTransport()
        let image = try makePNG(width: 8, height: 8)
        transport.answer(
            "https://cdn.example/pic.png",
            .success(FakeAnswer(body: image, headers: ["Content-Length": String(image.count)]))
        )
        let downloaded = try await makeClient(transport).downloadImage(from: "https://cdn.example/pic.png")
        #expect(downloaded == image)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
    }

    @Test func downloadRejectsContentThatIsNotAnImage() async {
        let transport = FakeTransport()
        transport.answer("https://cdn.example/page", .success(FakeAnswer(body: Data("<html>blocked</html>".utf8))))
        transport.answer("https://cdn.example/empty", .success(FakeAnswer(body: Data())))
        let client = makeClient(transport)
        await #expect(throws: SteamGridDBError.notAnImage) {
            try await client.downloadImage(from: "https://cdn.example/page")
        }
        await #expect(throws: SteamGridDBError.notAnImage) {
            try await client.downloadImage(from: "https://cdn.example/empty")
        }
    }

    @Test func downloadRejectsTruncatedBodies() async throws {
        let transport = FakeTransport()
        let image = try makePNG(width: 8, height: 8)
        transport.answer(
            "https://cdn.example/cut.png",
            .success(FakeAnswer(body: image, headers: ["Content-Length": String(image.count + 10)]))
        )
        await #expect(throws: SteamGridDBError.truncatedDownload(
            expectedBytes: image.count + 10,
            actualBytes: image.count
        )) {
            try await makeClient(transport).downloadImage(from: "https://cdn.example/cut.png")
        }
    }

    @Test func downloadFailsOnErrorStatusAndBadURL() async {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await #expect(throws: SteamGridDBError.badStatus(404)) {
            try await client.downloadImage(from: "https://cdn.example/missing.png")
        }
        await #expect(throws: SteamGridDBError.invalidURL) {
            try await client.downloadImage(from: "")
        }
    }

    // MARK: Artwork helper

    private func artworkTransport(iconURL: String = "https://cdn.example/icon.png") throws -> FakeTransport {
        let transport = FakeTransport()
        let icon = try makePNG(width: 64, height: 64)
        let cover = try makePNG(width: 60, height: 90)
        let banner = try makePNG(width: 192, height: 62)
        try transport.answerJSON("\(base)/search/autocomplete/Celeste", data: [["id": 11, "name": "Celeste"]])
        try transport.answerJSON(
            "\(base)/grids/game/11?dimensions=600x900",
            data: [["url": "https://cdn.example/cover.png", "thumb": "https://cdn.example/cover-thumb.png"]]
        )
        try transport.answerJSON(
            "\(base)/heroes/game/11",
            data: [["url": "https://cdn.example/banner.png"], ["url": "https://cdn.example/other.png"]]
        )
        try transport.answerJSON(
            "\(base)/icons/game/11",
            data: [["url": iconURL, "thumb": "https://cdn.example/icon-thumb.png"]]
        )
        for (url, data) in [
            ("https://cdn.example/icon.png", icon), ("https://cdn.example/icon-thumb.png", icon),
            ("https://cdn.example/cover.png", cover), ("https://cdn.example/banner.png", banner),
        ] {
            transport.answer(url, .success(FakeAnswer(body: data)))
        }
        return transport
    }

    @Test func fetchArtworkPicksTheFirstCandidateOfEachCategory() async throws {
        let transport = try artworkTransport()
        let request = SteamGridDBArtworkRequest(
            gameTitle: "  Celeste ", gameID: "abc", wantIcon: true, wantCover: true, wantBanner: true
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork.steamGridDBID == 11)
        let coverData = try #require(artwork.coverData)
        let bannerData = try #require(artwork.bannerData)
        #expect(ImageTools.decode(coverData)?.width == 60)
        #expect(ImageTools.decode(bannerData)?.width == 192)
        let iconData = try #require(artwork.iconPNG)
        let icon = try #require(ImageTools.decode(iconData))
        #expect(icon.width == 256 && icon.height == 256)
        #expect(transport.requestedURLs.contains("https://cdn.example/cover.png"))
        #expect(!transport.requestedURLs.contains("https://cdn.example/other.png"))
        #expect(!transport.requestedURLs.contains("https://cdn.example/cover-thumb.png"))
    }

    @Test func fetchArtworkOnlyDownloadsWhatWasRequested() async throws {
        let transport = try artworkTransport()
        let request = SteamGridDBArtworkRequest(
            gameTitle: "Celeste", gameID: "abc", wantIcon: true, wantCover: false, wantBanner: false
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork.iconPNG != nil)
        #expect(artwork.coverData == nil)
        #expect(artwork.bannerData == nil)
        #expect(!transport.requestedURLs.contains("https://cdn.example/cover.png"))
        #expect(!transport.requestedURLs.contains("https://cdn.example/banner.png"))
    }

    @Test func icoIconsAreFetchedThroughTheirThumbnail() async throws {
        let transport = try artworkTransport(iconURL: "https://cdn.example/icon.ICO?v=2")
        let request = SteamGridDBArtworkRequest(
            gameTitle: "Celeste", gameID: "abc", wantIcon: true, wantCover: false, wantBanner: false
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork.iconPNG != nil)
        #expect(transport.requestedURLs.contains("https://cdn.example/icon-thumb.png"))
        #expect(!transport.requestedURLs.contains { $0.contains(".ICO") })
        let candidate = SteamGridDBCandidate(url: "https://x/a.png", thumb: "https://x/a-thumb.png")
        #expect(SteamGridDBClient.iconDownloadURL(for: candidate) == "https://x/a.png")
    }

    @Test func fetchArtworkDropsInvalidDownloadsAndKeepsTheGameID() async throws {
        let transport = try artworkTransport()
        transport.answer("https://cdn.example/cover.png", .success(FakeAnswer(body: Data("oops".utf8))))
        transport.answer("https://cdn.example/banner.png", .success(FakeAnswer(statusCode: 500)))
        let request = SteamGridDBArtworkRequest(
            gameTitle: "Celeste", gameID: "abc", wantIcon: true, wantCover: true, wantBanner: true
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork.coverData == nil)
        #expect(artwork.bannerData == nil)
        #expect(artwork.iconPNG != nil)
        #expect(artwork.steamGridDBID == 11)
    }

    @Test func fetchArtworkWithoutATitleDoesNothing() async throws {
        let transport = try artworkTransport()
        let request = SteamGridDBArtworkRequest(
            gameTitle: "   ", gameID: "abc", wantIcon: true, wantCover: true, wantBanner: true
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork == SteamGridDBArtwork())
        #expect(transport.requests.isEmpty)
    }

    @Test func steamAppIDKeepsTheStoredSteamGridDBID() async throws {
        let transport = FakeTransport()
        let icon = try makePNG(width: 32, height: 32)
        try transport.answerJSON("\(base)/icons/steam/620", data: [["url": "https://cdn.example/i.png"]])
        transport.answer("https://cdn.example/i.png", .success(FakeAnswer(body: icon)))
        let request = SteamGridDBArtworkRequest(
            gameTitle: "Portal 2", gameID: "p2", steamGridDBID: 77, steamAppID: 620,
            wantIcon: true, wantCover: true, wantBanner: true
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        #expect(artwork.steamGridDBID == 77)
        #expect(artwork.iconPNG != nil)
        #expect(artwork.coverData == nil)
    }

    @Test func temporaryFilesFeedTheExistingArtworkPipeline() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let transport = try artworkTransport()
        let request = SteamGridDBArtworkRequest(
            gameTitle: "Celeste", gameID: "abc", wantIcon: true, wantCover: true, wantBanner: true
        )
        let artwork = await makeClient(transport).fetchArtwork(for: request)
        let files = try artwork.writeTemporaryFiles(in: paths.home + "/scratch", gameID: "abc")

        let iconPath = GameArtwork.saveIcon(temporaryPath: files.iconPath, gameID: "abc", paths: paths)
        let coverPath = GameArtwork.saveCover(temporaryPath: files.coverPath, gameID: "abc", paths: paths)
        GameArtwork.saveBanner(temporaryPath: files.bannerPath, gameID: "abc", paths: paths)

        #expect(iconPath == "\(paths.iconsDirectory)/abc.png")
        #expect(ImageTools.pixelSize(atPath: iconPath)?.width == 256)
        #expect(coverPath == "\(paths.coversDirectory)/abc.png")
        #expect(ImageTools.pixelSize(atPath: coverPath)?.width == GameArtwork.coverSize.width)
        let bannerSize = ImageTools.pixelSize(atPath: "\(paths.bannersDirectory)/abc.png")
        #expect(bannerSize?.width == GameArtwork.bannerSize.width)
        #expect(bannerSize?.height == GameArtwork.bannerSize.height)
    }

    @Test func missingCategoriesProduceNoTemporaryFiles() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let files = try SteamGridDBArtwork().writeTemporaryFiles(in: paths.home + "/scratch", gameID: "abc")
        #expect(files == SteamGridDBArtwork.TemporaryFiles())
    }

    // MARK: Settings

    @Test func settingsRequireEnabledAndANonEmptyKey() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try FaugusConfig.load(paths: paths, language: "en")
        #expect(!SteamGridDBSettings(configuration: configuration).isUsable)

        configuration.setValue("steamgriddb-enabled", bool: true)
        #expect(!SteamGridDBSettings(configuration: configuration).isUsable)

        configuration.setValue("steamgriddb-api-key", "\"\"")
        #expect(SteamGridDBSettings(configuration: configuration).apiKey.isEmpty)
        #expect(!SteamGridDBSettings(configuration: configuration).isUsable)

        configuration.setValue("steamgriddb-api-key", "\"abc123\"")
        let settings = SteamGridDBSettings(configuration: configuration)
        #expect(settings.apiKey == "abc123")
        #expect(settings.isEnabled)
        #expect(settings.isUsable)
        #expect(settings.makeClient(transport: FakeTransport()) != nil)

        configuration.setValue("steamgriddb-enabled", bool: false)
        let disabled = SteamGridDBSettings(configuration: configuration)
        #expect(!disabled.isUsable)
        #expect(disabled.makeClient(transport: FakeTransport()) == nil)
    }
}
