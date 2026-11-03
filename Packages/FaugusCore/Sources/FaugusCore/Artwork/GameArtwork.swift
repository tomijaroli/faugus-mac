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
        let pe = PEResources(path: path)
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let title = pe?.title() ?? fallback
        let icon = pe?.iconFile().flatMap { ImageTools.iconPNG(from: $0, size: 256) }
        return ExecutableInfo(title: title, iconPNG: icon)
    }

    /// `resize_temp_image`: skips the work when `dest` already holds exactly `temp`.
    @discardableResult
    static func installResized(temp: String, dest: String, width: Int, height: Int) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest), fm.contentsEqual(atPath: temp, andPath: dest) { return true }
        do {
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try ImageTools.resizeFile(from: temp, to: dest, width: width, height: height)
            return true
        } catch {
            return false
        }
    }

    /// Stores the chosen cover as `covers/<id>.png` (460x690). Returns the stored path, or `""`
    /// when there is no cover.
    public static func saveCover(temp: String?, gameID: String, paths: FaugusPaths) -> String {
        let dest = "\(paths.coversDir)/\(gameID).png"
        guard let temp, FileManager.default.fileExists(atPath: temp) else {
            try? FileManager.default.removeItem(atPath: dest)
            return ""
        }
        return installResized(temp: temp, dest: dest, width: coverSize.width, height: coverSize.height) ? dest : ""
    }

    /// `save_temp_banner`: `banners/<id>.png` (1920x620). A missing temp leaves the banner alone,
    /// as upstream does.
    public static func saveBanner(temp: String?, gameID: String, paths: FaugusPaths) {
        guard let temp, FileManager.default.fileExists(atPath: temp) else { return }
        installResized(
            temp: temp, dest: "\(paths.bannersDir)/\(gameID).png", width: bannerSize.width, height: bannerSize.height)
    }

    /// Moves the chosen icon to `icons/<id>.png` and drops a legacy `.ico`. Returns the icon
    /// path when the file exists, else `""`.
    public static func saveIcon(temp: String?, gameID: String, paths: FaugusPaths) -> String {
        let fm = FileManager.default
        let dest = "\(paths.iconsDir)/\(gameID).png"
        try? fm.removeItem(atPath: "\(paths.iconsDir)/\(gameID).ico")
        if let temp, fm.fileExists(atPath: temp) {
            try? fm.createDirectory(atPath: paths.iconsDir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dest)
            do { try fm.copyItem(atPath: temp, toPath: dest) } catch { return fm.fileExists(atPath: dest) ? dest : "" }
        } else if temp == nil {
            // The user removed the icon.
            try? fm.removeItem(atPath: dest)
        }
        return fm.fileExists(atPath: dest) ? dest : ""
    }

    // MARK: Downloads (Load from URL)

    public enum DownloadError: Error { case badURL, notAnImage, tooLarge, failed }

    /// `on_load_url` checks: an http(s) URL ending in a known image extension.
    public static func validatedImageURL(_ text: String) -> URL? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host != nil
        else { return nil }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "bmp", "gif"].contains(ext) ? url : nil
    }

    public static let maxDownloadBytes = 25 * 1024 * 1024

    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DownloadError.failed }
        guard data.count <= maxDownloadBytes else { throw DownloadError.tooLarge }
        guard ImageTools.isValid(data) else { throw DownloadError.notAnImage }
        return data
    }
}
