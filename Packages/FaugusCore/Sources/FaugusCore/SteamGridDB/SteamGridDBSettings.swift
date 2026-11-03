import Foundation

/// The two SteamGridDB settings of `config.json` (`steamgriddb-enabled`, `steamgriddb-api-key`).
public struct SteamGridDBSettings: Equatable, Sendable {
    public static let enabledKey = "steamgriddb-enabled"
    public static let apiKeyKey = "steamgriddb-api-key"

    public let isEnabled: Bool
    /// The key with surrounding double quotes removed (`.strip('"')` upstream).
    public let apiKey: String

    public init(isEnabled: Bool, apiKey: String) {
        self.isEnabled = isEnabled
        self.apiKey = apiKey.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public init(configuration: FaugusConfig) {
        self.init(
            isEnabled: configuration.bool(SteamGridDBSettings.enabledKey),
            apiKey: configuration.string(SteamGridDBSettings.apiKeyKey)
        )
    }

    /// Upstream `steamgriddb_enabled` in the Add / Edit dialogs: enabled AND a non-empty key.
    public var isUsable: Bool {
        isEnabled && !apiKey.isEmpty
    }

    /// A client for the stored key, or `nil` when SteamGridDB is off or has no key.
    public func makeClient(transport: any SteamGridDBTransport = URLSessionSteamGridDBTransport())
        -> SteamGridDBClient?
    {
        isUsable ? SteamGridDBClient(apiKey: apiKey, transport: transport) : nil
    }
}
