import Foundation

/// How a game's graphics backend turns into DLL overrides and environment (plan section 4).
public struct GraphicsPlan: Equatable, Sendable {
    public let requested: GraphicsBackend
    /// What will actually be used after capability checks.
    public let backend: GraphicsBackend
    public let dllOverrides: [(dll: String, mode: String)]
    public let environment: [String: String]
    /// Human-readable notes for `faugus.log`, e.g. why a backend was swapped.
    public let notes: [String]

    public static func == (l: GraphicsPlan, r: GraphicsPlan) -> Bool {
        l.requested == r.requested && l.backend == r.backend && l.environment == r.environment
            && l.dllOverrides.map { "\($0.dll)=\($0.mode)" } == r.dllOverrides.map { "\($0.dll)=\($0.mode)" }
            && l.notes == r.notes
    }

    /// `default` follows `mac-graphics-backend` (default `dxvk`); a config value of `default`
    /// also means `dxvk`.
    public static func effectiveRequest(game: Game, config: FaugusConfig) -> GraphicsBackend {
        var b = game.graphics ?? .default
        if b == .default {
            b = GraphicsBackend(rawValue: config.macGraphicsBackend) ?? .dxvk
        }
        if b == .default {
            b = .dxvk
        }
        return b
    }

    public static func resolve(
        requested: GraphicsBackend, capabilities: RunnerCapabilities, dxvkInstalled _: Bool = true
    ) -> GraphicsPlan {
        var backend = requested
        var notes: [String] = []

        func downgrade(to new: GraphicsBackend, because reason: String) {
            notes.append("graphics: \(backend.rawValue) unavailable (\(reason)); using \(new.rawValue)")
            backend = new
        }

        // dxmt / d3dmetal exist only on runners that declare them. Anything else falls back.
        if backend == .dxmt, !capabilities.dxmt {
            downgrade(to: .dxvk, because: "runner does not declare DXMT")
        }
        if backend == .d3dmetal, !capabilities.d3dmetal {
            downgrade(
                to: .dxvk,
                because: "runner does not declare D3DMetal"
            )
        }

        if backend == .dxvk, !capabilities.vulkan {
            downgrade(to: .wined3d, because: "runner has no Vulkan/MoltenVK")
        }
        if backend == .wined3dVulkan, !capabilities.vulkan {
            downgrade(
                to: .wined3d,
                because: "runner has no Vulkan/MoltenVK"
            )
        }

        var overrides: [(String, String)] = []
        var env: [String: String] = [:]
        switch backend {
        case .dxvk, .default:
            overrides = [("d3d11", "n,b"), ("d3d10core", "n,b")]
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        // DXVK_ASYNC is deliberately left unset.
        case .wined3d:
            overrides = [("d3d11", "b"), ("d3d10core", "b")]
        case .wined3dVulkan:
            overrides = [("d3d11", "b"), ("d3d10core", "b")]
            env["WINE_D3D_CONFIG"] = "renderer=vulkan"
        case .dxmt, .d3dmetal:
            // Declared by the runner; the runner's own manifest drives the setup (not in P1).
            overrides = [("d3d11", "b"), ("d3d10core", "b")]
        }
        return GraphicsPlan(
            requested: requested,
            backend: backend,
            dllOverrides: overrides,
            environment: env,
            notes: notes
        )
    }

    var usesDXVKDLLs: Bool {
        backend == .dxvk
    }
}

/// `WINEDLLOVERRIDES` parsing and merging. Entries from the user win over Faugus's.
public enum DLLOverrides {
    /// `a,b=n,b;c=d` becomes `[("a","n,b") ...]` in order.
    public static func parse(_ value: String) -> [(dll: String, mode: String)] {
        var out: [(String, String)] = []
        for group in value.split(separator: ";") where !group.isEmpty {
            guard let eq = group.lastIndex(of: "=") else { continue }
            let mode = String(group[group.index(after: eq)...])
            for dll in group[..<eq].split(separator: ",") where !dll.isEmpty {
                out.append((String(dll), mode))
            }
        }
        return out
    }

    public static func serialize(_ entries: [(dll: String, mode: String)]) -> String {
        // Group consecutive DLLs that share a mode: `d3d11,d3d10core=n,b`.
        var groups: [(mode: String, dlls: [String])] = []
        for e in entries {
            if let i = groups.firstIndex(where: { $0.mode == e.mode }) {
                groups[i].dlls.append(e.dll)
            } else {
                groups.append((e.mode, [e.dll]))
            }
        }
        return groups.map { "\($0.dlls.joined(separator: ","))=\($0.mode)" }.joined(separator: ";")
    }

    /// `base` entries are replaced by same-named `overriding` entries (user choice wins).
    public static func merge(base: [(dll: String, mode: String)], overriding: [(dll: String, mode: String)]) -> [(
        dll: String,
        mode: String
    )] {
        let names = Set(overriding.map(\.dll))
        return base.filter { !names.contains($0.dll) } + overriding
    }
}
