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
        var object = JSONObject()
        object["version"] = .int(Int64(version))
        object["runner"] = .string(runner)
        object["wine"] = .string(wine)
        object["created"] = .string(created)
        object["dxvk"] = dxvk.map(JSONValue.string) ?? .null
        return .object(object)
    }

    public init(runner: String, wine: String, created: String, dxvk: String? = nil) {
        self.runner = runner
        self.wine = wine
        self.created = created
        self.dxvk = dxvk
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let runner = object["runner"]?.stringValue else { return nil }
        self.init(
            runner: runner, wine: object["wine"]?.stringValue ?? "", created: object["created"]?.stringValue ?? "",
            dxvk: object["dxvk"]?.stringValue
        )
        version = Int(object["version"]?.intValue ?? 1)
    }
}

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case creationFailed(String)
    public var description: String {
        switch self {
        case let .creationFailed(message): "Prefix creation failed: \(message)"
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
        let markerJSON = JSONFile.load(markerPath(prefix), default: .null)
        return PrefixMarker(json: markerJSON)
    }

    /// A prefix is ready when Wine initialised it (`system.reg`) and Faugus recorded it.
    public func isCreated(prefix: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: prefix + "/system.reg") && fileManager
            .fileExists(atPath: markerPath(prefix))
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
        var environment = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: baseEnvironment)
        environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml="
        environment["WINEDEBUG"] = "-all"

        let boot = try await ProcessRunner.run(
            runner.wineBinary,
            ["wineboot", "-u"],
            environment: environment,
            currentDirectory: prefix
        )
        // Let wineserver finish writing the registry before anyone touches the prefix.
        _ = try? await ProcessRunner.run(
            runner.wineserverBinary,
            ["-w"],
            environment: environment,
            currentDirectory: prefix
        )

        guard boot.succeeded, FileManager.default.fileExists(atPath: prefix + "/system.reg") else {
            throw PrefixError.creationFailed(boot.stderr.isEmpty ? "wineboot exited with \(boot.status)" : boot.stderr)
        }

        let version = await (try? ProcessRunner.run(runner.wineBinary, ["--version"], environment: environment))?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let marker = PrefixMarker(
            runner: runner.name, wine: version, created: ISO8601DateFormatter().string(from: Date())
        )
        try JSONFile.save(marker.json(), to: markerPath(prefix))
    }

    /// `wineboot -u` on an already-populated prefix after a Linux import. Gecko/Mono prompts
    /// stay suppressed so restore never blocks on a dialog.
    public func updateAfterImport(
        prefix: String,
        runner: InstalledRunner,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        var environment = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: baseEnvironment)
        environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml="
        environment["WINEDEBUG"] = "-all"
        _ = try await ProcessRunner.run(
            runner.wineBinary,
            ["wineboot", "-u"],
            environment: environment,
            currentDirectory: prefix
        )
        _ = try? await ProcessRunner.run(
            runner.wineserverBinary,
            ["-w"],
            environment: environment,
            currentDirectory: prefix
        )
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
        let fileManager = FileManager.default
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
                if fileManager.fileExists(atPath: syswow64) {
                    try copyReplacing(from: dxvk.x32Directory + "/" + dll, to: syswow64 + "/" + dll)
                }
            }
            marker.dxvk = DXVKComponent.tag
        } else if marker.dxvk != nil {
            for dll in DXVKComponent.dllNames {
                let builtin64Path = runner.wineRoot + "/lib/wine/x86_64-windows/" + dll
                let builtin32Path = runner.wineRoot + "/lib/wine/i386-windows/" + dll
                if fileManager.fileExists(atPath: builtin64Path) {
                    try copyReplacing(from: builtin64Path, to: system32 + "/" + dll)
                }
                if fileManager.fileExists(atPath: builtin32Path), fileManager.fileExists(atPath: syswow64) {
                    try copyReplacing(from: builtin32Path, to: syswow64 + "/" + dll)
                }
            }
            marker.dxvk = nil
        } else {
            return
        }
        try JSONFile.save(marker.json(), to: markerPath(prefix))
    }

    private func dllsPresent(dxvk _: DXVKComponent, system32: String, syswow64 _: String) -> Bool {
        let fileManager = FileManager.default
        return DXVKComponent.dllNames.allSatisfy { fileManager.fileExists(atPath: system32 + "/" + $0) }
    }

    /// Linux Proton ships its own native d3d DLLs; swap them for this runner's builtins.
    public func replaceProtonGraphicsDLLs(prefix: String, runner: InstalledRunner) throws {
        let fileManager = FileManager.default
        let system32 = windowsDirectory(prefix) + "/system32"
        let syswow64 = windowsDirectory(prefix) + "/syswow64"
        for dllName in LinuxFixup.protonGraphicsDLLs {
            let builtin64 = runner.wineRoot + "/lib/wine/x86_64-windows/" + dllName
            let builtin32 = runner.wineRoot + "/lib/wine/i386-windows/" + dllName
            let system32Path = system32 + "/" + dllName
            if fileManager.fileExists(atPath: builtin64), LinuxFixup.shouldReplaceGraphicsDLL(at: system32Path) {
                try copyReplacing(from: builtin64, to: system32Path)
            }
            let syswow64Path = syswow64 + "/" + dllName
            if fileManager.fileExists(atPath: builtin32), fileManager.fileExists(atPath: syswow64),
               LinuxFixup.shouldReplaceGraphicsDLL(at: syswow64Path)
            {
                try copyReplacing(from: builtin32, to: syswow64Path)
            }
        }
        if var marker = marker(prefix: prefix) {
            marker.dxvk = nil
            try JSONFile.save(marker.json(), to: markerPath(prefix))
        }
    }

    private func copyReplacing(from source: String, to destination: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.copyItem(atPath: source, toPath: destination)
    }
}
