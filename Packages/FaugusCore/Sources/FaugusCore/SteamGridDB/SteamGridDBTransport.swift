import Foundation

/// The network layer under `SteamGridDBClient`. Tests inject a fake; the app uses
/// `URLSessionSteamGridDBTransport`.
public protocol SteamGridDBTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport: one `URLSession` request per call, no automatic caching.
public struct URLSessionSteamGridDBTransport: SteamGridDBTransport {
    public enum Failure: Error { case notHTTP }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw Failure.notHTTP }
        return (data, httpResponse)
    }
}

public enum SteamGridDBError: Error, Equatable {
    case invalidURL
    case badStatus(Int)
    /// `verified_content`: the body is shorter or longer than the `Content-Length` header.
    case truncatedDownload(expectedBytes: Int, actualBytes: Int)
    case tooLarge
    case notAnImage
}
