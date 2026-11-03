import Foundation

/// What the Add / Edit dialog wants from SteamGridDB for one game.
public struct SteamGridDBArtworkRequest: Equatable, Sendable {
    public var gameTitle: String
    /// The Faugus game id; only used to name the temporary files.
    public var gameID: String
    /// A SteamGridDB game id picked earlier (the `steamgriddb_id` field or an autocomplete choice).
    public var steamGridDBID: Int?
    public var steamAppID: Int?
    public var wantIcon: Bool
    public var wantCover: Bool
    public var wantBanner: Bool

    public init(
        gameTitle: String,
        gameID: String,
        steamGridDBID: Int? = nil,
        steamAppID: Int? = nil,
        wantIcon: Bool,
        wantCover: Bool,
        wantBanner: Bool
    ) {
        self.gameTitle = gameTitle
        self.gameID = gameID
        self.steamGridDBID = steamGridDBID
        self.steamAppID = steamAppID
        self.wantIcon = wantIcon
        self.wantCover = wantCover
        self.wantBanner = wantBanner
    }
}

/// Downloaded artwork. A category is `nil` when it was not requested, SteamGridDB has nothing for
/// it, or the download was not a valid image.
public struct SteamGridDBArtwork: Equatable, Sendable {
    /// A 256 px PNG (`apply_downloaded_artwork` normalizes icons the same way).
    public var iconPNG: Data?
    public var coverData: Data?
    public var bannerData: Data?
    /// The SteamGridDB game id to store in the game's `steamgriddb_id` field.
    public var steamGridDBID: Int?

    public init(iconPNG: Data? = nil, coverData: Data? = nil, bannerData: Data? = nil, steamGridDBID: Int? = nil) {
        self.iconPNG = iconPNG
        self.coverData = coverData
        self.bannerData = bannerData
        self.steamGridDBID = steamGridDBID
    }

    /// Temporary files in the form `GameArtwork.saveIcon/saveCover/saveBanner` take.
    public struct TemporaryFiles: Equatable, Sendable {
        public var iconPath: String?
        public var coverPath: String?
        public var bannerPath: String?
    }

    /// Writes each present category to a file in `directory` (created if needed).
    public func writeTemporaryFiles(in directory: String, gameID: String) throws -> TemporaryFiles {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func write(_ data: Data?, suffix: String) throws -> String? {
            guard let data else { return nil }
            let path = "\(directory)/steamgriddb-\(gameID)-\(suffix)"
            try JSONFile.atomicWrite(data, to: path)
            return path
        }
        return try TemporaryFiles(
            iconPath: write(iconPNG, suffix: "icon.png"),
            coverPath: write(coverData, suffix: "cover.image"),
            bannerPath: write(bannerData, suffix: "banner.image")
        )
    }
}

extension SteamGridDBClient {
    /// `get_artwork` / `refresh_single_artwork` for the SteamGridDB path: the first candidate per
    /// wanted category (icon: first icon, its thumbnail when the icon is an `.ico`; cover: first
    /// grid; banner: first hero), downloaded concurrently and verified as images.
    public func fetchArtwork(for request: SteamGridDBArtworkRequest) async -> SteamGridDBArtwork {
        var artwork = SteamGridDBArtwork(steamGridDBID: request.steamGridDBID)
        let title = request.gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.wantIcon || request.wantCover || request.wantBanner,
              !title.isEmpty || request.steamAppID != nil else { return artwork }

        let foundCandidates = await candidates(
            gameName: title, limit: 1, gameID: request.steamGridDBID, steamAppID: request.steamAppID
        )
        artwork.steamGridDBID = foundCandidates.gameID ?? request.steamGridDBID

        let iconURL = request.wantIcon ? foundCandidates.icons.first.map { Self.iconDownloadURL(for: $0) } : nil
        let coverURL = request.wantCover ? foundCandidates.grids.first?.url : nil
        let bannerURL = request.wantBanner ? foundCandidates.heroes.first?.url : nil

        async let iconData = optionalImage(from: iconURL)
        async let coverData = optionalImage(from: coverURL)
        async let bannerData = optionalImage(from: bannerURL)
        artwork.iconPNG = await iconData.flatMap { ImageTools.iconPNG(from: $0, size: 256) }
        artwork.coverData = await coverData
        artwork.bannerData = await bannerData
        return artwork
    }

    /// An `.ico` is fetched through its thumbnail (a plain raster image).
    static func iconDownloadURL(for candidate: SteamGridDBCandidate) -> String {
        let pathPart = candidate.url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? candidate.url
        return pathPart.lowercased().hasSuffix(".ico") ? candidate.thumb : candidate.url
    }

    private func optionalImage(from urlString: String?) async -> Data? {
        guard let urlString else { return nil }
        return try? await downloadImage(from: urlString)
    }
}
