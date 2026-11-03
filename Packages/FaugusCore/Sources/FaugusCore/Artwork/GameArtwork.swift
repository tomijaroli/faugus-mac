import Foundation

/// Cover, banner and icon files of a game, and what the Add / Edit dialog does with them.
public enum GameArtwork {
    public static let coverSize = (width: 460, height: 690)
    public static let bannerSize = (width: 1920, height: 620)

    public struct ExecutableInfo: Sendable {
        public var title: String
        public var iconPNG: Data?
    }

    /// `fill_from_executable`: the title from the version resources (else the file name without
    /// its extension) and the main icon as a 256 px PNG. Nothing is executed.
    public static func inspect(executable path: String) -> ExecutableInfo {
        let peResources = PEResources(path: path)
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let title = peResources?.title() ?? fallback
        let icon = peResources?.iconFile().flatMap { ImageTools.iconPNG(from: $0, size: 256) }
        return ExecutableInfo(title: title, iconPNG: icon)
    }

    /// `resize_temp_image`: skips the work when `destinationPath` already holds exactly `temporaryPath`.
    @discardableResult
    static func installResized(temporaryPath: String, destinationPath: String, width: Int, height: Int) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationPath),
           fileManager.contentsEqual(atPath: temporaryPath, andPath: destinationPath)
        {
            return true
        }
        do {
            try fileManager.createDirectory(
                atPath: (destinationPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try ImageTools.resizeFile(from: temporaryPath, to: destinationPath, width: width, height: height)
            return true
        } catch {
            return false
        }
    }

    /// Stores the chosen cover as `covers/<id>.png` (460x690). Returns the stored path, or `""`
    /// when there is no cover.
    public static func saveCover(temporaryPath: String?, gameID: String, paths: FaugusPaths) -> String {
        let destinationPath = "\(paths.coversDirectory)/\(gameID).png"
        guard let temporaryPath, FileManager.default.fileExists(atPath: temporaryPath) else {
            try? FileManager.default.removeItem(atPath: destinationPath)
            return ""
        }
        return installResized(
            temporaryPath: temporaryPath, destinationPath: destinationPath, width: coverSize.width,
            height: coverSize.height
        ) ? destinationPath : ""
    }

    /// `save_temp_banner`: `banners/<id>.png` (1920x620). A missing temp leaves the banner alone,
    /// as upstream does.
    public static func saveBanner(temporaryPath: String?, gameID: String, paths: FaugusPaths) {
        guard let temporaryPath, FileManager.default.fileExists(atPath: temporaryPath) else { return }
        installResized(
            temporaryPath: temporaryPath,
            destinationPath: "\(paths.bannersDirectory)/\(gameID).png",
            width: bannerSize.width,
            height: bannerSize.height
        )
    }

    /// Moves the chosen icon to `icons/<id>.png` and drops a legacy `.ico`. Returns the icon
    /// path when the file exists, else `""`.
    public static func saveIcon(temporaryPath: String?, gameID: String, paths: FaugusPaths) -> String {
        let fileManager = FileManager.default
        let destinationPath = "\(paths.iconsDirectory)/\(gameID).png"
        try? fileManager.removeItem(atPath: "\(paths.iconsDirectory)/\(gameID).ico")
        if let temporaryPath, fileManager.fileExists(atPath: temporaryPath) {
            try? fileManager.createDirectory(atPath: paths.iconsDirectory, withIntermediateDirectories: true)
            try? fileManager.removeItem(atPath: destinationPath)
            do {
                try fileManager.copyItem(atPath: temporaryPath, toPath: destinationPath)
            } catch {
                return fileManager.fileExists(atPath: destinationPath) ? destinationPath : ""
            }
        } else if temporaryPath == nil {
            // The user removed the icon.
            try? fileManager.removeItem(atPath: destinationPath)
        }
        return fileManager.fileExists(atPath: destinationPath) ? destinationPath : ""
    }

    // MARK: Downloads (Load from URL)

    public enum DownloadError: Error { case badURL, notAnImage, tooLarge, failed }

    /// `on_load_url` checks: an http(s) URL ending in a known image extension.
    public static func validatedImageURL(_ text: String) -> URL? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        let fileExtension = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "bmp", "gif"].contains(fileExtension) ? url : nil
    }

    public static let maxDownloadBytes = 25 * 1024 * 1024

    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else { throw DownloadError.failed }
        guard data.count <= maxDownloadBytes else { throw DownloadError.tooLarge }
        guard ImageTools.isValid(data) else { throw DownloadError.notAnImage }
        return data
    }
}
