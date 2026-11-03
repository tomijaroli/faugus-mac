import Foundation

/// Reads Gcenx's `macOS_Wine_builds` release feed (plan section 4).
public enum GcenxFeed {
    public static let repository = "Gcenx/macOS_Wine_builds"
    public static let pageSize = 100

    public static func releasesURL(page: Int) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(pageSize)&page=\(page)")!
    }

    /// Parses one page of the GitHub releases API into downloadable runners, newest version
    /// first within each flavor. Drafts and prereleases are ignored.
    public static func parse(_ json: JSONValue) -> [RemoteRunner] {
        guard let releases = json.arrayValue else { return [] }
        var out: [RemoteRunner] = []
        for rel in releases.compactMap(\.objectValue) {
            if rel["draft"]?.boolValue == true || rel["prerelease"]?.boolValue == true { continue }
            guard let tag = rel["tag_name"]?.stringValue else { continue }
            let published = rel["published_at"]?.stringValue ?? ""
            for asset in (rel["assets"]?.arrayValue ?? []).compactMap(\.objectValue) {
                guard let name = asset["name"]?.stringValue,
                    let flavor = flavor(fromAsset: name),
                    let urlString = asset["browser_download_url"]?.stringValue,
                    let url = URL(string: urlString)
                else { continue }
                var sha: String?
                if let digest = asset["digest"]?.stringValue, digest.hasPrefix("sha256:") {
                    sha = String(digest.dropFirst("sha256:".count))
                }
                out.append(
                    RemoteRunner(
                        flavor: flavor, version: tag, assetName: name, downloadURL: url,
                        size: asset["size"]?.intValue ?? 0, sha256: sha, publishedAt: published))
            }
        }
        return out.sorted {
            if $0.flavor != $1.flavor { return $0.flavor.rawValue < $1.flavor.rawValue }
            return VersionKey($0.version) > VersionKey($1.version)
        }
    }

    /// `wine-staging-11.21-osx64.tar.xz` becomes `.staging`.
    static func flavor(fromAsset name: String) -> WineFlavor? {
        guard name.hasPrefix("wine-"), name.hasSuffix("-osx64.tar.xz") else { return nil }
        let rest = name.dropFirst("wine-".count)
        for f in WineFlavor.allCases where rest.hasPrefix(f.rawValue + "-") { return f }
        return nil
    }

    public static func latest(_ flavor: WineFlavor, in runners: [RemoteRunner]) -> RemoteRunner? {
        runners.filter { $0.flavor == flavor }.max { VersionKey($0.version) < VersionKey($1.version) }
    }

    /// Fetches every page (100 releases each).
    public static func fetchAll(session: URLSession = .shared) async throws -> [RemoteRunner] {
        var all: [RemoteRunner] = []
        var page = 1
        while true {
            var req = URLRequest(url: releasesURL(page: page))
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Faugus-for-Mac", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RunnerError.downloadFailed("GitHub API returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let json = try JSONParser.parse(data)
            all += parse(json)
            if (json.arrayValue?.count ?? 0) < pageSize { break }
            page += 1
        }
        return all
    }
}
