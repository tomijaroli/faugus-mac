import AppKit
import FaugusCore
import SwiftUI

/// Draft for the Add / Edit dialog (Windows game type; the other types arrive in P2).
struct GameEditorState: Identifiable {
    let id = UUID()
    var original: Game?
    var title = ""
    var path = ""
    var prefix = ""
    var prefixEdited = false
    var runner = "Default"
    var graphics: GraphicsBackend = .default
    var launchArguments = ""
    var gameArguments = ""

    @MainActor static func new(model: AppModel) -> GameEditorState {
        GameEditorState()
    }

    @MainActor static func edit(_ game: Game, model: AppModel) -> GameEditorState {
        var s = GameEditorState()
        s.original = game
        s.title = game.title
        s.path = game.path
        s.prefix = game.prefix
        s.prefixEdited = true
        s.runner = game.runner.isEmpty ? "Default" : game.runner
        s.graphics = game.graphics ?? .default
        s.launchArguments = game.launchArguments
        s.gameArguments = game.gameArguments
        return s
    }
}

struct GameEditorView: View {
    let model: AppModel
    @State var state: GameEditorState
    let dismiss: () -> Void

    init(model: AppModel, state: GameEditorState, dismiss: @escaping () -> Void) {
        self.model = model
        self._state = State(initialValue: state)
        self.dismiss = dismiss
    }

    private var defaultPrefixBase: String {
        model.paths.expand(model.config?.string("default-prefix", default: model.paths.prefixesDir) ?? model.paths.prefixesDir)
    }

    private var suggestedID: String {
        GameID.unique(base: GameID.format(title: state.title), existing: model.existingIDs())
    }

    private var effectivePrefix: String {
        if state.prefixEdited, !state.prefix.isEmpty { return state.prefix }
        return defaultPrefixBase + "/" + (state.original?.gameID ?? suggestedID)
    }

    /// dxmt/d3dmetal appear only when the chosen runner declares them (plan section 4).
    private var graphicsChoices: [GraphicsBackend] {
        var out: [GraphicsBackend] = [.default, .dxvk, .wined3d, .wined3dVulkan]
        let store = RunnerStore(paths: model.paths)
        let caps: RunnerCapabilities? =
            state.runner == "Default" || state.runner.hasSuffix("Latest")
            ? nil : store.find(name: state.runner)?.capabilities
        if let caps {
            if caps.dxmt { out.append(.dxmt) }
            if caps.d3dmetal { out.append(.d3dmetal) }
        }
        if !out.contains(state.graphics) { out.append(state.graphics) }
        return out
    }

    private func graphicsLabel(_ g: GraphicsBackend) -> String {
        switch g {
        case .default: return model.translator("Default")
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        case .wined3dVulkan: return "WineD3D (Vulkan)"
        case .dxmt: return "DXMT"
        case .d3dmetal: return "D3DMetal"
        }
    }

    var body: some View {
        let t = model.translator
        let isEdit = state.original != nil
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? t.format("Edit %s", state.original?.title ?? "") : t("New Game/App"))
                .font(.title2.weight(.semibold)).padding([.top, .horizontal], 20)
            Form {
                TextField(t("Title"), text: $state.title)
                    .accessibilityIdentifier("editor-title")
                HStack {
                    TextField(t("Path"), text: $state.path)
                        .accessibilityIdentifier("editor-path")
                    Button("…") { choose(t("Select the game executable"), directories: false) { state.path = $0 } }
                }
                HStack {
                    TextField(t("Prefix"), text: Binding(
                        get: { state.prefixEdited ? state.prefix : effectivePrefix },
                        set: { state.prefix = $0; state.prefixEdited = true }))
                    .help(t("Path to the prefix"))
                    .accessibilityIdentifier("editor-prefix")
                    Button("…") { choose(t("Select a prefix location"), directories: true) { state.prefix = $0; state.prefixEdited = true } }
                }
                Picker("Runner", selection: $state.runner) {
                    Text(t("Default")).tag("Default")
                    Text(WineFlavor.staging.latestIdentifier).tag(WineFlavor.staging.latestIdentifier)
                    ForEach(model.installedRunners()) { Text($0.name).tag($0.name) }
                }
                Picker("Graphics", selection: $state.graphics) {
                    ForEach(graphicsChoices, id: \.self) { Text(graphicsLabel($0)).tag($0) }
                }
                TextField(t("Launch Arguments"), text: $state.launchArguments)
                TextField(t("Game Arguments"), text: $state.gameArguments)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Confirm")) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.title.trimmingCharacters(in: .whitespaces).isEmpty || state.path.isEmpty)
                    .accessibilityIdentifier("editor-confirm")
            }
            .padding(20)
        }
        .frame(width: 560)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private func confirm() {
        var game = state.original ?? Game(gameID: suggestedID, title: state.title)
        game.title = state.title.trimmingCharacters(in: .whitespaces)
        game.path = state.path
        game.prefix = effectivePrefix
        game.runner = state.runner
        game.graphics = state.graphics == .default ? nil : state.graphics
        game.launchArguments = state.launchArguments
        game.gameArguments = state.gameArguments
        model.save(game)
        dismiss()
    }

    private func choose(_ message: String, directories: Bool, _ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.canCreateDirectories = directories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }
}
