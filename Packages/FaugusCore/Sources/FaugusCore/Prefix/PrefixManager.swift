import Foundation

/// `.faugus-prefix.json`, written after a prefix is created by Faugus.
public struct PrefixMarker: Equatable, Sendable {
    public static let fileName = ".faugus-prefix.json"
    public var version = 1
    public var runner: String
    public var wine: String
    public var created: String
    /// DXVK-macOS tag whose DLLs currently sit in `system32`/`syswow64`; `nil` means builtin DLLs.
    public var dxvk: String?

    public func json() -> JSONValue {
        var o = JSONObject()
        o["version"] = .int(Int64(version))
        o["runner"] = .string(runner)
        o["wine"] = .string(wine)
        o["created"] = .string(created)
        o["dxvk"] = dxvk.map(JSONValue.string) ?? .null
        return .object(o)
    }

    public init(runner: String, wine: String, created: String, dxvk: String? = nil) {
        self.runner = runner
        self.wine = wine
        self.created = created
        self.dxvk = dxvk
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue, let runner = o["runner"]?.stringValue else { return nil }
        self.init(
            runner: runner, wine: o["wine"]?.stringValue ?? "", created: o["created"]?.stringValue ?? "",
            dxvk: o["dxvk"]?.stringValue
        )
        version = Int(o["version"]?.intValue ?? 1)
    }
}

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case creationFailed(String)
    public var description: String {
        switch self {
        case let .creationFailed(m): "Prefix creation failed: \(m)"
        }
    }
}

/// Creates and maintains Wine prefixes (plan section 3 "Prefix").
public struct PrefixManager: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func markerPath(_ prefix: String) -> String {
        prefix + "/" + PrefixMarker.fileName
    }

    public func marker(prefix: String) -> PrefixMarker? {
        let v = JSONFile.load(markerPath(prefix), default: .null)
        return PrefixMarker(json: v)
    }

    /// A prefix is ready when Wine initialised it (`system.reg`) and Faugus recorded it.
    public func isCreated(prefix: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: prefix + "/system.reg") && fm.fileExists(atPath: markerPath(prefix))
    }

    public func windowsDirectory(_ prefix: String) -> String {
        prefix + "/drive_c/windows"
    }

    /// `wineboot -u` with winemenubuilder disabled. Gecko/Mono prompts are suppressed during
    /// creation only, so the prefix is created without any dialog.
    public func create(
        prefix: String,
        runner: InstalledRunner,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        var env = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: baseEnvironment)
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml="
        env["WINEDEBUG"] = "-all"

        let boot = try await ProcessRunner.run(
            runner.wineBinary,
            ["wineboot", "-u"],
            environment: env,
            currentDirectory: prefix
        )
        // Let wineserver finish writing the registry before anyone touches the prefix.
        _ = try? await ProcessRunner.run(runner.wineserverBinary, ["-w"], environment: env, currentDirectory: prefix)

        guard boot.succeeded, FileManager.default.fileExists(atPath: prefix + "/system.reg") else {
            throw PrefixError.creationFailed(boot.stderr.isEmpty ? "wineboot exited with \(boot.status)" : boot.stderr)
        }

        let version = await (try? ProcessRunner.run(runner.wineBinary, ["--version"], environment: env))?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let marker = PrefixMarker(
            runner: runner.name, wine: version, created: ISO8601DateFormatter().string(from: Date())
        )
        try JSONFile.save(marker.json(), to: markerPath(prefix))
    }

    /// Makes the DLLs in `prefix` match `plan`: DXVK copies in, or the runner's builtin DLLs
    /// are restored. Never writes into the runner.
    public func applyGraphics(
        _ plan: GraphicsPlan,
        prefix: String,
        runner: InstalledRunner,
        dxvk: DXVKComponent
    ) throws {
        guard var marker = marker(prefix: prefix) else { return }
        let fm = FileManager.default
        let system32 = windowsDirectory(prefix) + "/system32"
        let syswow64 = windowsDirectory(prefix) + "/syswow64"

        if plan.backend == .dxvk {
            guard dxvk.isInstalled else { throw RunnerError.noRelease("DXVK-macOS is not installed") }
            if marker.dxvk == DXVKComponent.tag,
               dllsPresent(dxvk: dxvk, system32: system32, syswow64: syswow64)
            {
                return
            }
            for dll in DXVKComponent.dllNames {
                try copyReplacing(from: dxvk.x64Directory + "/" + dll, to: system32 + "/" + dll)
                if fm.fileExists(atPath: syswow64) {
                    try copyReplacing(from: dxvk.x32Directory + "/" + dll, to: syswow64 + "/" + dll)
                }
            }
            marker.dxvk = DXVKComponent.tag
        } else if marker.dxvk != nil {
            for dll in DXVKComponent.dllNames {
                let b64 = runner.wineRoot + "/lib/wine/x86_64-windows/" + dll
                let b32 = runner.wineRoot + "/lib/wine/i386-windows/" + dll
                if fm.fileExists(atPath: b64) {
                    try copyReplacing(from: b64, to: system32 + "/" + dll)
                }
                if fm.fileExists(atPath: b32), fm.fileExists(atPath: syswow64) {
                    try copyReplacing(from: b32, to: syswow64 + "/" + dll)
                }
            }
            marker.dxvk = nil
        } else {
            return
        }
        try JSONFile.save(marker.json(), to: markerPath(prefix))
    }

    private func dllsPresent(dxvk _: DXVKComponent, system32: String, syswow64 _: String) -> Bool {
        let fm = FileManager.default
        return DXVKComponent.dllNames.allSatisfy { fm.fileExists(atPath: system32 + "/" + $0) }
    }

    private func copyReplacing(from src: String, to dst: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst) {
            try fm.removeItem(atPath: dst)
        }
        try fm.copyItem(atPath: src, toPath: dst)
    }
}
