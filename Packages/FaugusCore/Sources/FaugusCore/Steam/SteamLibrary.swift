import Foundation

/// Read-only view of the user's Steam installation (upstream `steam_setup.py`, macOS layout).
///
/// Faugus never writes anything under the Steam folder.
public struct SteamLibrary: Sendable {
    public struct User: Equatable, Sendable {
        public var accountID: String
        public var name: String
        public init(accountID: String, name: String) { self.accountID = accountID; self.name = name }
        /// `Name (accountid)`, the label upstream shows in the user picker.
        public var label: String { name == accountID ? accountID : "\(name) (\(accountID))" }
    }

    public struct InstalledGame: Equatable, Sendable {
        public var appID: String
        public var name: String
        public init(appID: String, name: String) { self.appID = appID; self.name = name }
    }

    /// Upstream hides tools that Steam lists as installed apps.
    public static let titleFilterKeywords = ["Proton", "Steam Linux Runtime", "Steamworks Common Redistributables"]

    static let steamID64Base: Int64 = 76_561_197_960_265_728

    public let root: String
    public init(root: String) { self.root = root }

    /// `~/Library/Application Support/Steam`.
    public init(home: String) { self.init(root: home + "/Library/Application Support/Steam") }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
    }

    /// Whether Steam looks installed: its data folder or the app bundle exists.
    public func isSteamInstalled(home: String, bundles: [String]? = nil) -> Bool {
        if exists { return true }
        return (bundles ?? ["/Applications/Steam.app", home + "/Applications/Steam.app"]).contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private var userdata: String { root + "/userdata" }

    // MARK: Users

    public func accountIDs() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: userdata) else { return [] }
        return names.filter { name in
            var isDir: ObjCBool = false
            return name != "0" && !name.isEmpty && name.allSatisfy(\.isASCII) && name.allSatisfy(\.isNumber)
                && FileManager.default.fileExists(atPath: userdata + "/" + name, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    /// Accounts with a `userdata` folder, named from `loginusers.vdf`, sorted by name.
    public func users() -> [User] {
        let ids = accountIDs()
        guard !ids.isEmpty else { return [] }
        var names: [String: String] = [:]
        if let login = VDF.parse(file: root + "/config/loginusers.vdf")?["users"] {
            for (steamID64, info) in login.entries {
                guard let n = Int64(steamID64) else { continue }
                let persona = info["PersonaName"]?.string ?? ""
                names[String(n - Self.steamID64Base)] = persona.isEmpty ? String(n - Self.steamID64Base) : persona
            }
        }
        return ids.map { User(accountID: $0, name: names[$0] ?? $0) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Libraries and installed games

    /// Steam library folders. macOS Steam keeps `libraryfolders.vdf` in `steamapps/`; the
    /// Linux location `config/` is read too. The Steam folder itself is always a library.
    public func libraryFolders() -> [String] {
        var out: [String] = []
        for file in [root + "/steamapps/libraryfolders.vdf", root + "/config/libraryfolders.vdf"] {
            guard let vdf = VDF.parse(file: file)?["libraryfolders"] else { continue }
            for (_, entry) in vdf.entries {
                if let p = entry["path"]?.string, !p.isEmpty, !out.contains(p) { out.append(p) }
            }
        }
        // The Steam folder is always a library; compare real paths so a symlinked or differently
        // spelled entry does not list every game twice.
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        if !out.contains(where: { real($0) == real(root) }) { out.insert(root, at: 0) }
        var seen: Set<String> = []
        return out.filter { seen.insert(real($0)).inserted }
    }

    private func familyMembers(accountID: String) -> Set<String> {
        let file = userdata + "/" + accountID + "/config/localconfig.vdf"
        guard let members = VDF.parse(file: file)?.path("UserLocalConfigStore", "FamilyGroup", "members") else { return [] }
        return Set(members.entries.compactMap { $0.value["accountid"]?.string }.filter { !$0.isEmpty })
    }

    /// Installed games from every library's `appmanifest_*.acf`. For an account, only games it
    /// or a family-sharing member owns. `accountID` nil or "all" lists everything.
    public func installedGames(accountID: String? = nil) -> [InstalledGame] {
        let account = (accountID == nil || accountID == "all" || accountID?.isEmpty == true) ? nil : accountID
        let family = account.map(familyMembers)
        var games: [InstalledGame] = []
        var seenAppIDs: Set<String> = []
        for lib in libraryFolders() {
            let dir = lib + "/steamapps"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                let appID = String(file.dropFirst("appmanifest_".count).dropLast(".acf".count))
                guard !appID.isEmpty, let state = VDF.parse(file: dir + "/" + file)?["AppState"],
                    let name = state["name"]?.string, !name.isEmpty
                else { continue }
                if let account, let family {
                    var owner: String?
                    if let last = state["LastOwner"]?.string, let n = Int64(last) { owner = String(n - Self.steamID64Base) }
                    if owner != account, !(owner.map(family.contains) ?? false) { continue }
                }
                if seenAppIDs.insert(appID).inserted { games.append(InstalledGame(appID: appID, name: name)) }
            }
        }
        return games.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The games the picker offers: installed, minus Proton, runtimes and redistributables.
    public func pickerGames(accountID: String?) -> [InstalledGame] {
        installedGames(accountID: accountID).filter { game in
            let lower = game.name.lowercased()
            return !Self.titleFilterKeywords.contains { lower.contains($0.lowercased()) }
        }
    }

    /// The game's install folder (`steamapps/common/<installdir>`), if it exists.
    public func installFolder(appID: String) -> String? {
        for lib in libraryFolders() {
            let manifest = lib + "/steamapps/appmanifest_\(appID).acf"
            guard let state = VDF.parse(file: manifest)?["AppState"] else { continue }
            guard let dir = state["installdir"]?.string, !dir.isEmpty, !dir.contains("/"), dir != ".." else { return nil }
            let full = lib + "/steamapps/common/" + dir
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue ? full : nil
        }
        return nil
    }

    // MARK: Playtime

    /// Steam's own playtime in minutes, summed over the account (or every account).
    public func playtimeMinutes(appID: String, accountID: String?) -> Int {
        let ids = (accountID == nil || accountID == "all" || accountID?.isEmpty == true)
            ? accountIDs() : [accountID!]
        var total = 0
        for id in ids {
            let file = userdata + "/" + id + "/config/localconfig.vdf"
            guard let apps = VDF.parse(file: file)?.path("UserLocalConfigStore", "Software", "Valve", "Steam", "apps"),
                let entry = apps[appID], let minutes = entry["Playtime"]?.string.flatMap({ Int($0) })
            else { continue }
            total += minutes
        }
        return total
    }

    // MARK: Icon

    /// The smallest image in `appcache/librarycache/<appid>` that is not a header or capsule,
    /// which is the game's icon (upstream `get_steam_icon_path`).
    public func iconPath(appID: String) -> String? {
        let cache = root + "/appcache/librarycache/" + appID
        guard let walker = FileManager.default.enumerator(atPath: cache) else { return nil }
        let skipped: Set<String> = ["header.jpg", "library_600x900.jpg", "library_capsule.jpg"]
        var best: (area: Int, path: String)?
        for case let rel as String in walker where rel.lowercased().hasSuffix(".jpg") {
            let name = (rel as NSString).lastPathComponent
            guard !skipped.contains(name) else { continue }
            let full = cache + "/" + rel
            guard let size = ImageTools.pixelSize(atPath: full) else { continue }
            let area = size.width * size.height
            if best == nil || area < best!.area || (area == best!.area && full < best!.path) { best = (area, full) }
        }
        return best?.path
    }
}

/// How a Steam-type game is started (the Mac replacement for `steam -applaunch <appid>`).
public enum SteamLaunch {
    /// `steam://rungameid/<id>`, or `steam://run/<id>//<arguments>/` when the game has arguments.
    public static func url(appID: String, gameArguments: String) -> String? {
        let id = appID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let args = gameArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return "steam://rungameid/\(id)" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = args.addingPercentEncoding(withAllowedCharacters: allowed) ?? args
        return "steam://run/\(id)//\(encoded)/"
    }
}
