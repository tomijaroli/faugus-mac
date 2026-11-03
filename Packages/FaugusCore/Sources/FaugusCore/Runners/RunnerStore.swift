import Foundation

public enum RunnerResolution: Equatable, Sendable {
    case installed(InstalledRunner)
    /// `Wine-Staging Latest` was requested but no Staging runner is installed.
    case missingLatest(WineFlavor)
    case missing(String)
}

/// Installed Wine runners under `~/Library/Application Support/Faugus/runners`.
public struct RunnerStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func installed() -> [InstalledRunner] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.runnersDir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }
            .compactMap { find(name: $0) }
            .sorted { lhs, rhs in
                if lhs.flavor != rhs.flavor {
                    return (lhs.flavor?.rawValue ?? "~") < (rhs.flavor?.rawValue ?? "~")
                }
                return VersionKey(lhs.version ?? lhs.name) > VersionKey(rhs.version ?? rhs.name)
            }
    }

    public func find(name: String) -> InstalledRunner? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let dir = paths.runnersDir + "/" + name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
              let root = RunnerStore.locateWineRoot(in: dir)
        else { return nil }
        let (flavor, version) = RunnerStore.parseName(name)
        return InstalledRunner(
            name: name, directory: dir, wineRoot: root, flavor: flavor, version: version,
            capabilities: RunnerStore.detectCapabilities(wineRoot: root, runnerDirectory: dir)
        )
    }

    /// `Default` follows the configured default runner; `<Flavor> Latest` picks the highest
    /// installed version of that flavor.
    public func resolve(_ identifier: String, defaultRunner: String) -> RunnerResolution {
        let id = identifier == "Default" ? defaultRunner : identifier
        for flavor in WineFlavor.allCases where id == flavor.latestIdentifier {
            if let best = installed().filter({ $0.flavor == flavor }).first {
                return .installed(best)
            }
            return .missingLatest(flavor)
        }
        if let r = find(name: id) {
            return .installed(r)
        }
        return .missing(id)
    }

    // MARK: Layout

    /// Gcenx archives contain `<Flavor>.app/Contents/Resources/wine/bin/wine`; manually
    /// provided runners may be a plain tree with `bin/wine`.
    public static func locateWineRoot(in directory: String) -> String? {
        let fm = FileManager.default
        func hasWine(_ root: String) -> Bool {
            fm.isExecutableFile(atPath: root + "/bin/wine")
        }
        if hasWine(directory) {
            return directory
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let root = directory + "/" + entry + "/Contents/Resources/wine"
            if hasWine(root) {
                return root
            }
        }
        // One level of nesting (e.g. `<dir>/wine/bin/wine`).
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let root = directory + "/" + entry
            if hasWine(root) {
                return root
            }
        }
        return nil
    }

    /// `Wine-Staging-11.21` becomes `(.staging, "11.21")`.
    public static func parseName(_ name: String) -> (WineFlavor?, String?) {
        for f in WineFlavor.allCases where name.hasPrefix(f.runnerPrefix + "-") {
            return (f, String(name.dropFirst(f.runnerPrefix.count + 1)))
        }
        return (nil, nil)
    }

    public static func detectCapabilities(wineRoot: String, runnerDirectory: String) -> RunnerCapabilities {
        let fm = FileManager.default
        var caps = RunnerCapabilities()
        caps.vulkan = fm.fileExists(atPath: wineRoot + "/lib/libMoltenVK.dylib")
            && fm.fileExists(atPath: wineRoot + "/lib/libvulkan.dylib")
        caps.sdl = fm.fileExists(atPath: wineRoot + "/lib/libSDL2.dylib")
        caps.gstreamer = fm.fileExists(atPath: wineRoot + "/lib/GStreamer.framework")

        // DXMT and D3DMetal are never detected, only declared by the runner's own manifest.
        let manifest = JSONFile.load(runnerDirectory + "/faugus-runner.json", default: .object(JSONObject()))
        if let o = manifest.objectValue {
            caps.dxmt = o["dxmt"]?.boolValue ?? false
            caps.d3dmetal = o["d3dmetal"]?.boolValue ?? false
        }
        return caps
    }
}
