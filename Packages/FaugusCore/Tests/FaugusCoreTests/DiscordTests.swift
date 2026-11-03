import Darwin
@testable import FaugusCore
import Foundation
import Testing

// MARK: - Suite

@Suite("Discord", .serialized)
struct DiscordTests {
    // MARK: Frames

    @Test func frameIsLittleEndianOpcodeLengthAndJSON() {
        let frame = DiscordFrame(opcode: .handshake, json: ["v": 1, "client_id": "123"])
        let encoded = frame.encoded()
        let payload = frame.payload
        #expect(Array(encoded.prefix(4)) == [0, 0, 0, 0])
        #expect(Array(encoded[4 ..< 8]) == [UInt8(payload.count), 0, 0, 0])
        #expect(Data(encoded.dropFirst(8)) == payload)
        #expect(frame.json == ["v": 1, "client_id": "123"])

        let activityFrame = DiscordFrame(opcode: .frame, json: ["cmd": "SET_ACTIVITY"])
        #expect(activityFrame.encoded().first == 1)
    }

    @Test func largePayloadLengthUsesAllFourBytes() throws {
        let payload = Data(repeating: 0x20, count: 0x0102)
        let encoded = DiscordFrame(opcode: 7, payload: payload).encoded()
        #expect(Array(encoded.prefix(8)) == [7, 0, 0, 0, 0x02, 0x01, 0, 0])
        let header = try #require(DiscordFrame.decodeHeader(encoded))
        #expect(header.opcode == 7)
        #expect(header.payloadLength == 0x0102)
    }

    @Test func framesAreExtractedFromAStreamOneAtATime() throws {
        let first = DiscordFrame(opcode: .frame, json: ["a": 1])
        let second = DiscordFrame(opcode: .close, json: ["b": 2])
        var buffer = first.encoded() + second.encoded().prefix(10)
        #expect(try DiscordFrame.extractFrame(from: &buffer) == first)
        // The second frame is still partial.
        #expect(try DiscordFrame.extractFrame(from: &buffer) == nil)
        buffer.append(second.encoded().dropFirst(10))
        #expect(try DiscordFrame.extractFrame(from: &buffer) == second)
        #expect(buffer.isEmpty)
        #expect(DiscordFrame.decodeHeader(Data([1, 2, 3])) == nil)
    }

    @Test func absurdFrameLengthIsRejected() {
        var buffer = Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: DiscordIPCError.payloadTooLarge(0x7FFF_FFFF)) {
            try DiscordFrame.extractFrame(from: &buffer)
        }
    }

    // MARK: Sockets

    @Test func runtimeDirectoriesIncludeTheTemporaryDirectoryXdgAndPrivateTemporaryFolder() {
        let directories = DiscordSocketLocator.defaultRuntimeDirectories(
            environment: ["TMPDIR": "/private/var/x/T/", "XDG_RUNTIME_DIR": "/run/user/1", "HOME": "/h"]
        )
        #expect(directories.contains("/private/var/x/T"))
        #expect(directories.contains("/run/user/1"))
        #expect(directories.last == "/tmp")
        #expect(Set(directories).count == directories.count)
        #expect(directories.allSatisfy { !$0.hasSuffix("/") || $0 == "/" })
        let tmpdirIndex = directories.firstIndex(of: "/private/var/x/T") ?? -1
        let xdgIndex = directories.firstIndex(of: "/run/user/1") ?? -1
        #expect(tmpdirIndex < xdgIndex)
    }

    @Test func socketPathsAreListedPerDirectoryInOrder() {
        let existing: Set = ["/a/discord-ipc-0", "/a/discord-ipc-9", "/b/discord-ipc-3", "/b/discord-ipc-10"]
        let paths = DiscordSocketLocator.socketPaths(in: ["/a", "/b", "/c"]) { existing.contains($0) }
        #expect(paths == ["/a/discord-ipc-0", "/a/discord-ipc-9", "/b/discord-ipc-3"])
    }

    @Test func handshakeThenSetActivityReachTheServer() async throws {
        let server = FakeDiscordServer(socketIndex: 3)
        try server.start()
        defer { server.stop() }

        let connection = try #require(DiscordConnection.connect(
            clientID: "4711", socketDirectories: ["/nonexistent-directory", server.directory], timeout: 3
        ))
        #expect(connection.isOpen)
        #expect(connection.socketPath == server.socketPath)
        let activity = DiscordFrame(opcode: .frame, json: ["cmd": "SET_ACTIVITY", "nonce": "n-1"])
        try connection.send(activity)

        #expect(await waitUntil { server.receivedActivities.count == 1 })
        #expect(server.handshakeClientIDs == ["4711"])
        let received = try #require(server.receivedActivities.first)
        #expect(received.clientID == "4711")
        #expect(received.payload == ["cmd": "SET_ACTIVITY", "nonce": "n-1"])

        // Discord's replies to our frames can be read, and are thrown away when nobody wants them.
        let reply = try connection.receiveFrame()
        #expect(reply.json?.objectValue?["evt"]?.stringValue == "READY")
        #expect(connection.discardPendingReplies())

        connection.close()
        connection.close()
        #expect(!connection.isOpen)
        #expect(throws: DiscordIPCError.connectionClosed) { try connection.send(activity) }
        #expect(await waitUntil { server.closedConnectionCount == 1 })
    }

    @Test func connectingWithoutAnyDiscordYieldsNil() {
        #expect(DiscordConnection.connect(clientID: "1", socketDirectories: ["/nonexistent-directory"]) == nil)
        #expect(DiscordConnection.makeAddress(path: "/tmp/" + String(repeating: "x", count: 200)) == nil)
    }

    @Test func aRejectedHandshakeIsNotAConnection() async throws {
        let server = FakeDiscordServer(replyOpcode: .close)
        try server.start()
        defer { server.stop() }
        #expect(DiscordConnection.connect(clientID: "1", socketDirectories: [server.directory]) == nil)
        #expect(await waitUntil { server.closedConnectionCount == 1 })
    }

    @Test func discardingRepliesNoticesThatDiscordWentAway() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let connection = try #require(DiscordConnection.connect(clientID: "1", socketDirectories: [server.directory]))
        defer { connection.close() }
        #expect(connection.discardPendingReplies())
        server.dropConnections()
        #expect(await waitUntil { !connection.discardPendingReplies() })
    }

    // MARK: Detectable applications

    private static let applicationsJSON = """
    [
      {"id": "100", "name": "Fun Game", "executables": [
        {"os": "win32", "name": "FunGame.exe"},
        {"os": "linux", "name": ">funlauncher/Launcher.exe", "is_launcher": true},
        {"os": "darwin", "name": "FunGame.app"},
        {"os": "win32", "name": "C:\\\\Games\\\\Deep\\\\Run.EXE"}]},
      {"id": "200", "name": "Other", "executables": [{"os": "win32", "name": "fungame.exe", "is_launcher": true}]},
      {"id": "300", "name": "No executables"},
      {"name": "No id", "executables": [{"os": "win32", "name": "noid.exe"}]}
    ]
    """

    @Test func detectableResponseBecomesABasenameIndex() throws {
        let index = try #require(DiscordDetectableIndex(applicationsJSON: JSONParser.parse(Self.applicationsJSON)))
        #expect(Set(index.entriesByBasename.keys) == ["fungame.exe", "launcher.exe", "run.exe"])
        #expect(index.entries(forBasename: "fungame.exe") == [
            DiscordDetectableEntry(
                executableName: "fungame.exe", applicationID: "100", applicationName: "Fun Game", isLauncher: false
            ),
            DiscordDetectableEntry(
                executableName: "fungame.exe", applicationID: "200", applicationName: "Other", isLauncher: true
            ),
        ])
        // Leading `>` removed, backslashes turned into slashes, lowercased.
        #expect(index.entries(forBasename: "launcher.exe").first?.executableName == "funlauncher/launcher.exe")
        #expect(index.entries(forBasename: "launcher.exe").first?.isLauncher == true)
        #expect(index.entries(forBasename: "run.exe").first?.executableName == "c:/games/deep/run.exe")
        #expect(index.entries(forBasename: "fungame.app").isEmpty)
        #expect(DiscordDetectableIndex(applicationsJSON: ["not": "an array"]) == nil)
    }

    @Test func cacheFormatRoundTripsAndReadsUpstreamFiles() throws {
        let index = try #require(DiscordDetectableIndex(applicationsJSON: JSONParser.parse(Self.applicationsJSON)))
        #expect(DiscordDetectableIndex(cacheJSON: index.cacheJSON) == index)
        // Upstream writes `{basename: [[name, id, application name, is_launcher], ...]}`.
        let upstream = try JSONParser.parse(#"{"a.exe": [["x/a.exe", "9", "Nine", true], ["short"]]}"#)
        let parsed = try #require(DiscordDetectableIndex(cacheJSON: upstream))
        #expect(parsed.entries(forBasename: "a.exe") == [
            DiscordDetectableEntry(
                executableName: "x/a.exe", applicationID: "9", applicationName: "Nine", isLauncher: true
            )
        ])
    }

    private final class FetchCounter: @unchecked Sendable {
        let requests = LockedValue<[URLRequest]>([])
    }

    private func makeLoader(
        paths: FaugusPaths, now: Date, counter: FetchCounter, response: Result<String, URLError>
    ) -> DiscordDetectableLoader {
        DiscordDetectableLoader(
            paths: paths,
            fetch: { request in
                counter.requests.update { $0.append(request) }
                return try Data(response.get().utf8)
            },
            now: { now }
        )
    }

    private func writeCache(_ paths: FaugusPaths, ageInDays: Double, now: Date) throws {
        let cachePath = paths.dataDirectory + "/discord-detectable.json"
        let stale = DiscordDetectableIndex(entriesByBasename: ["stale.exe": [
            DiscordDetectableEntry(
                executableName: "stale.exe",
                applicationID: "1",
                applicationName: "S",
                isLauncher: false
            )
        ]])
        try JSONFile.save(stale.cacheJSON, to: cachePath)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageInDays * 86400)], ofItemAtPath: cachePath
        )
    }

    @Test func aCacheUnderSevenDaysOldIsUsedWithoutDownloading() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let now = Date()
        try writeCache(paths, ageInDays: 6.9, now: now)
        let counter = FetchCounter()
        let index = await makeLoader(
            paths: paths,
            now: now,
            counter: counter,
            response: .success(Self.applicationsJSON)
        )
        .load()
        #expect(index.entries(forBasename: "stale.exe").count == 1)
        #expect(counter.requests.value.isEmpty)
    }

    @Test func anOldCacheIsRefetchedAndRewritten() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let now = Date()
        try writeCache(paths, ageInDays: 7.1, now: now)
        let counter = FetchCounter()
        let loader = makeLoader(paths: paths, now: now, counter: counter, response: .success(Self.applicationsJSON))
        let index = await loader.load()
        #expect(index.entries(forBasename: "fungame.exe").count == 2)
        #expect(index.entries(forBasename: "stale.exe").isEmpty)

        let request = try #require(counter.requests.value.first)
        #expect(request.url?.absoluteString == "https://discord.com/api/v10/applications/detectable")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Faugus-Launcher")
        #expect(loader.cachePath == paths.dataDirectory + "/discord-detectable.json")

        // The new cache is on disk and (its modification time being real) fresh on the next call.
        let cached = try #require(DiscordDetectableIndex(cacheJSON: JSONFile.loadOrThrow(loader.cachePath)))
        #expect(cached == index)
        let second = await makeLoader(
            paths: paths,
            now: Date(),
            counter: counter,
            response: .failure(URLError(.notConnectedToInternet))
        )
        .load()
        #expect(second == index)
        #expect(counter.requests.value.count == 1)
    }

    @Test func aFailedDownloadFallsBackToTheStaleCacheThenToNothing() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let now = Date()
        let counter = FetchCounter()
        let offline = Result<String, URLError>.failure(URLError(.notConnectedToInternet))

        let withoutCache = await makeLoader(paths: paths, now: now, counter: counter, response: offline).load()
        #expect(withoutCache.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.dataDirectory + "/discord-detectable.json"))

        try writeCache(paths, ageInDays: 30, now: now)
        let withStaleCache = await makeLoader(paths: paths, now: now, counter: counter, response: offline).load()
        #expect(withStaleCache.entries(forBasename: "stale.exe").count == 1)

        // A response that is not the application list does not clobber the cache either.
        let garbage = await makeLoader(
            paths: paths,
            now: now,
            counter: counter,
            response: .success(#"{"message":"rate limited"}"#)
        )
        .load()
        #expect(garbage.entries(forBasename: "stale.exe").count == 1)
        #expect(counter.requests.value.count == 3)
    }

    // MARK: Target resolution

    private static let targetIndexJSON = """
    [
      {"id": "100", "name": "Deep Run", "executables": [{"os": "win32", "name": "C:\\\\Games\\\\Deep\\\\Run.exe"}]},
      {"id": "400", "name": "Relative", "executables": [{"os": "win32", "name": "bin/relgame.exe"}]},
      {"id": "500", "name": "Some Launcher", "executables": [{"os": "win32", "name": "launch.exe", "is_launcher": true}]},
      {"id": "600", "name": "Real Game", "executables": [{"os": "win32", "name": "game.exe"}]},
      {"id": "700", "name": "Dual Launcher", "executables": [{"os": "win32", "name": "dual.exe", "is_launcher": true}]},
      {"id": "800", "name": "Dual Game", "executables": [{"os": "win32", "name": "dual.exe"}]},
      {"id": "905", "name": "Cool Game Deluxe Edition", "executables": [{"os": "win32", "name": "coolgame.exe"}]},
      {"id": "910", "name": "Cool Game", "executables": [{"os": "win32", "name": "coolgame.exe"}]},
      {"id": "920", "name": "Cool Game Launcher", "executables": [{"os": "win32", "name": "coolgame.exe", "is_launcher": true}]}
    ]
    """

    func targetIndex() throws -> DiscordDetectableIndex {
        try #require(DiscordDetectableIndex(applicationsJSON: JSONParser.parse(Self.targetIndexJSON)))
    }

    private func resolver(
        title: String = "Unrelated Title", executablePath: String = "/Games/unknown.exe",
        processes: [ProcessCandidate] = [], others: [String] = [],
        iconProvider: @escaping DiscordIconProvider = { nil }
    ) -> DiscordTargetResolver {
        DiscordTargetResolver(
            game: DiscordGameIdentity(gameID: "this-game", title: title, executablePath: executablePath),
            processProvider: { processes }, otherRunningGameIDs: { others }, iconProvider: iconProvider
        )
    }

    @Test func aWineProcessIsRecognisedByItsRewrittenWindowsPath() async throws {
        let index = try targetIndex()
        let match = resolver(processes: [
            ProcessCandidate(name: "wine64-preloader", firstArgument: "C:\\Games\\Deep\\Run.exe")
        ])
        #expect(await match.resolve(using: index) == DiscordTarget(clientID: "100"))

        // Same basename, different folder: not the registered game.
        let elsewhere = resolver(processes: [
            ProcessCandidate(name: "Run.exe", firstArgument: "D:\\Other\\Run.exe")
        ])
        #expect(await elsewhere.resolve(using: index)?.clientID == DiscordApplication.clientID)
    }

    @Test func aBareProcessNameIsCompletedWithItsWorkingDirectory() async throws {
        let index = try targetIndex()
        let withDirectory = resolver(processes: [
            ProcessCandidate(name: "relgame.exe", firstArgument: "", workingDirectory: "/Games/Rel/Bin")
        ])
        #expect(await withDirectory.resolve(using: index)?.clientID == "400")
        let wrongDirectory = resolver(processes: [
            ProcessCandidate(name: "relgame.exe", firstArgument: "", workingDirectory: "/Games/Rel/Other")
        ])
        #expect(await wrongDirectory.resolve(using: index)?.clientID == DiscordApplication.clientID)
        let noDirectory = resolver(processes: [ProcessCandidate(name: "relgame.exe", firstArgument: "")])
        #expect(await noDirectory.resolve(using: index)?.clientID == DiscordApplication.clientID)
    }

    @Test func aGameBeatsALauncherWhateverTheProcessOrder() async throws {
        let index = try targetIndex()
        let launcher = ProcessCandidate(name: "launch.exe", firstArgument: "")
        let game = ProcessCandidate(name: "game.exe", firstArgument: "")
        #expect(await resolver(processes: [launcher, game]).resolve(using: index)?.clientID == "600")
        #expect(await resolver(processes: [game, launcher]).resolve(using: index)?.clientID == "600")
        #expect(await resolver(processes: [launcher]).resolve(using: index)?.clientID == "500")
        // Within one executable name the non-launcher entry wins as well.
        let dual = ProcessCandidate(name: "dual.exe", firstArgument: "")
        #expect(await resolver(processes: [dual]).resolve(using: index)?.clientID == "800")
    }

    @Test func aRunningProcessBeatsEverythingElse() async throws {
        let index = try targetIndex()
        let candidate = resolver(
            title: "Cool Game", executablePath: "C:\\Games\\CoolGame.exe",
            processes: [ProcessCandidate(name: "game.exe", firstArgument: "")], others: ["another-game"]
        )
        #expect(await candidate.resolve(using: index)?.clientID == "600")
    }

    @Test func theTitleAndExecutableNameFindTheApplicationWhenNothingRuns() async throws {
        let index = try targetIndex()
        // Neither name equals the title: "contains" matches 905 and 910, the lowest id wins.
        let longer = resolver(title: "Cool Game: Deluxe!", executablePath: "D:\\Games\\CoolGame.EXE")
        #expect(await longer.resolve(using: index) == DiscordTarget(clientID: "905"))
        // An exact name beats "contains" even though 905 has the lower id; launcher 920 is never used.
        let exact = resolver(title: "cool-game", executablePath: "/Games/coolgame.exe")
        #expect(await exact.resolve(using: index) == DiscordTarget(clientID: "910"))
        // Title contained in the name.
        let shorter = resolver(title: "Cool", executablePath: "/Games/coolgame.exe")
        #expect(await shorter.resolve(using: index) == DiscordTarget(clientID: "905"))
        // Same executable, unrelated title: not that application.
        let unrelated = resolver(title: "Totally Different", executablePath: "/Games/coolgame.exe")
        #expect(await unrelated.resolve(using: index)?.clientID == DiscordApplication.clientID)
    }

    @Test func nothingIsShownWhileAnotherGameIsRunning() async throws {
        let index = try targetIndex()
        #expect(await resolver(others: ["another-game"]).resolve(using: index) == nil)
        // Its own id in the list is not "another game".
        #expect(await resolver(others: ["this-game"]).resolve(using: index)?.clientID == DiscordApplication.clientID)
    }

    @Test func theFallbackIsTheGenericApplicationWithOptionalIcon() async throws {
        let index = DiscordDetectableIndex()
        let plain = try #require(await resolver(title: "My Game").resolve(using: index))
        #expect(plain.clientID == DiscordApplication.clientID)
        #expect(plain.activity == ["details": "My Game", "status_display_type": 2])

        let iconCalls = LockedValue(0)
        let withIcon = resolver(title: "My Game") {
            iconCalls.update { $0 += 1 }
            return "https://example.com/icon.png"
        }
        let target = try #require(await withIcon.resolve(using: index))
        #expect(target.activity == [
            "details": "My Game", "status_display_type": 2, "assets": ["large_image": "https://example.com/icon.png"],
        ])
        #expect(await withIcon.resolve(using: index) == target)
        #expect(iconCalls.value == 1)

        // An empty answer means "no icon", and is not asked again.
        let emptyCalls = LockedValue(0)
        let emptyIcon = resolver(title: "My Game") {
            emptyCalls.update { $0 += 1 }
            return ""
        }
        #expect(await emptyIcon.resolve(using: index)?.activity == plain.activity)
        _ = await emptyIcon.resolve(using: index)
        #expect(emptyCalls.value == 1)
    }

    @Test func titleNormalisationKeepsOnlyLowercaseLettersAndDigits() {
        #expect(DiscordTargetResolver.alphanumericOnly("Cool Game: Deluxe-2!") == "coolgamedeluxe2")
        #expect(DiscordTargetResolver.alphanumericOnly("Pokémon") == "pokmon")
        #expect(DiscordTargetResolver.alphanumericOnly("---").isEmpty)
    }
}
