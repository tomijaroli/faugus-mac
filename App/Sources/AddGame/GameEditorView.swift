import AppKit
import FaugusCore
import SwiftUI

/// Draft for the Add / Edit dialog (Windows game type; the Steam type arrives later in P2).
struct GameEditorState: Identifiable {
    let id = UUID()
    var original: Game?
    var title = ""
    var path = ""
    var prefix = ""
    var prefixEdited = false
    var customRunner = false
    var runner = "Default"
    var graphics: GraphicsBackend = .default
    var launchArguments: [ArgLine] = [ArgLine(text: "")]
    var presets: [ArgLine] = [ArgLine(text: "")]
    var gameArguments = ""
    var preLaunch = ""
    var postLaunch = ""
    var discordRPC = false
    var noSleep = false
    var sdl = false
    var addAppEnabled = false
    var addAppPath = ""
    var addAppDelay = 0
    var addAppFirst = false

    @MainActor static func new(model: AppModel) -> GameEditorState {
        var s = GameEditorState()
        let cfg = model.config
        s.sdl = cfg?.bool("sdl-enabled") ?? false
        s.noSleep = cfg?.bool("no-sleep-enabled") ?? false
        s.discordRPC = cfg?.bool("discord-rpc-enabled") ?? false
        s.loadPresets(model: model)
        return s
    }

    @MainActor static func edit(_ game: Game, model: AppModel) -> GameEditorState {
        var s = GameEditorState()
        s.original = game
        s.title = game.title
        s.path = game.path
        s.prefix = game.prefix
        s.prefixEdited = true
        s.customRunner = !(game.runner.isEmpty || game.runner == "Default")
        s.runner = game.runner.isEmpty ? "Default" : game.runner
        s.graphics = game.graphics ?? .default
        s.launchArguments = LaunchArgumentsEditor.normalized(
            LaunchArgumentLines.split(game.launchArguments).map { ArgLine(text: $0) })
        s.gameArguments = game.gameArguments
        s.preLaunch = game.preLaunch
        s.postLaunch = game.postLaunch
        s.discordRPC = game.discordRPC
        s.noSleep = game.noSleep
        s.sdl = game.sdlEnabled
        s.addAppEnabled = game.addAppEnabled
        s.addAppPath = game.addApp
        s.addAppDelay = Int(game.addAppDelay) ?? 0
        s.addAppFirst = game.addAppFirst
        s.loadPresets(model: model)
        return s
    }

    @MainActor private mutating func loadPresets(model: AppModel) {
        presets = LaunchArgumentsEditor.normalized(PresetsStore(paths: model.paths).load().map { ArgLine(text: $0) })
    }
}

struct GameEditorView: View {
    enum Page: Hashable { case general, settings }
    enum SettingsSection: Hashable { case tools, launchArguments, addApp }

    let model: AppModel
    @State var state: GameEditorState
    let dismiss: () -> Void

    @State private var page: Page = .general
    @State private var section: SettingsSection = .tools
    @State private var invalid: Set<GameEditing.InvalidField> = []
    @State private var warning: String?

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
            !state.customRunner || state.runner == "Default" || state.runner.hasSuffix("Latest")
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

    /// The runner a new game gets when "Specific Runner" is off: the configured default.
    private var runnerChoices: [String] {
        var names = [WineFlavor.staging.latestIdentifier] + model.installedRunners().map(\.name)
        if state.customRunner, state.runner != "Default", !names.contains(state.runner) { names.append(state.runner) }
        return names
    }

    var body: some View {
        let t = model.translator
        let isEdit = state.original != nil
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? t.format("Edit %s", state.original?.title ?? "") : t("New Game/App"))
                .font(.title2.weight(.semibold)).padding([.top, .horizontal], 20)
            Picker("", selection: $page) {
                Text(t("General")).tag(Page.general)
                Text(t("Settings")).tag(Page.settings)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 12)
            .accessibilityIdentifier("editor-pages")

            Group {
                switch page {
                case .general: general(t)
                case .settings: settings(t)
                }
            }
            .frame(minHeight: 360)

            HStack {
                Spacer()
                Button(t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Confirm")) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editor-confirm")
            }
            .padding(20)
        }
        .frame(width: 600)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .alert(warning ?? "", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
            Button(t("Ok")) {}
        }
    }

    // MARK: General page

    private func general(_ t: Translator) -> some View {
        Form {
            TextField(t("Title"), text: $state.title)
                .invalidMark(invalid.contains(.title))
                .accessibilityIdentifier("editor-title")
            HStack {
                TextField(t("Path"), text: $state.path)
                    .invalidMark(invalid.contains(.path))
                    .help(t("Path to the game executable"))
                    .accessibilityIdentifier("editor-path")
                SearchButton {
                    if let p = FilePicker.choose(message: t("Select the game executable"), startIn: state.path) { state.path = p }
                }
                .help(t("Select the game executable"))
            }
            HStack {
                TextField(t("Prefix"), text: Binding(
                    get: { state.prefixEdited ? state.prefix : effectivePrefix },
                    set: { state.prefix = $0; state.prefixEdited = true }))
                .invalidMark(invalid.contains(.prefix))
                .help(t("Path to the prefix"))
                .accessibilityIdentifier("editor-prefix")
                SearchButton {
                    if let p = FilePicker.choose(message: t("Select a prefix location"), directories: true) {
                        state.prefix = p
                        state.prefixEdited = true
                    }
                }
                .help(t("Select a prefix location"))
            }
            Toggle(t("Specific Runner"), isOn: $state.customRunner)
                .accessibilityIdentifier("editor-custom-runner")
            Picker("Runner", selection: Binding(
                get: { state.customRunner ? state.runner : defaultRunnerChoice },
                set: { state.runner = $0 })
            ) {
                ForEach(runnerChoices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .disabled(!state.customRunner)
            Picker("Graphics", selection: $state.graphics) {
                ForEach(graphicsChoices, id: \.self) { Text(graphicsLabel($0)).tag($0) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.title) { _, _ in invalid.remove(.title) }
        .onChange(of: state.path) { _, _ in invalid.remove(.path) }
        .onChange(of: state.prefix) { _, _ in invalid.remove(.prefix) }
        .onChange(of: state.customRunner) { _, custom in
            if !custom { state.runner = "Default" } else if state.runner == "Default" {
                state.runner = defaultRunnerChoice
            }
        }
    }

    /// `default-runner` when it is installed, else the first listed runner.
    private var defaultRunnerChoice: String {
        let d = model.config?.string("default-runner") ?? ""
        return runnerChoices.contains(d) ? d : (runnerChoices.first ?? "Default")
    }

    // MARK: Settings page

    private func settings(_ t: Translator) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                Text(t("Tools")).tag(SettingsSection.tools)
                Text(t("Launch Arguments")).tag(SettingsSection.launchArguments)
                Text(t("Additional Application")).tag(SettingsSection.addApp)
            }
            .labelsHidden()
            .padding(.horizontal, 20).padding(.top, 12)
            .accessibilityIdentifier("editor-settings-section")
            switch section {
            case .tools: tools(t)
            case .launchArguments:
                LaunchArgumentsEditor(t: t, arguments: $state.launchArguments, presets: $state.presets)
                    .padding(20)
            case .addApp: addApp(t)
            }
        }
    }

    private func tools(_ t: Translator) -> some View {
        Form {
            TextField(t("Game Arguments"), text: $state.gameArguments, prompt: Text("-d3d11 -fullscreen"))
                .accessibilityIdentifier("editor-game-arguments")
            HStack {
                TextField(t("Pre-launch"), text: $state.preLaunch)
                    .help(t("Command or script to run before the game"))
                    .accessibilityIdentifier("editor-pre-launch")
                SearchButton {
                    if let p = FilePicker.choose(message: t("Select a command or script"), startIn: state.preLaunch) { state.preLaunch = p }
                }
            }
            HStack {
                TextField(t("Post-launch"), text: $state.postLaunch)
                    .help(t("Command or script to run after the game"))
                    .accessibilityIdentifier("editor-post-launch")
                SearchButton {
                    if let p = FilePicker.choose(message: t("Select a command or script"), startIn: state.postLaunch) { state.postLaunch = p }
                }
            }
            Toggle("Discord RPC", isOn: $state.discordRPC)
                .help(t("Shows the running game as your Discord activity"))
            Toggle(t("No Sleep"), isOn: $state.noSleep)
                .help(t("Prevents the system from suspending while gaming"))
            Toggle("SDL", isOn: $state.sdl)
                .help(t("May fix gamepad issues with some games"))
        }
        .formStyle(.grouped)
    }

    private func addApp(_ t: Translator) -> some View {
        Form {
            Toggle(t("Enable"), isOn: $state.addAppEnabled)
                .accessibilityIdentifier("editor-addapp-enable")
            Group {
                HStack {
                    TextField(t("Path"), text: $state.addAppPath)
                        .help(t("Path to the application"))
                    SearchButton {
                        if let p = FilePicker.choose(message: t("Select an additional application"), startIn: state.addAppPath) {
                            state.addAppPath = p
                        }
                    }
                }
                Stepper(value: $state.addAppDelay, in: 0...60) {
                    HStack {
                        Text(t("Delay (seconds)"))
                        Spacer()
                        Text("\(state.addAppDelay)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle(t("Run the application first"), isOn: $state.addAppFirst)
            }
            .disabled(!state.addAppEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: Save

    private func confirm() {
        let t = model.translator
        let title = state.title
        let prefix = GameEditing.normalizedPath(effectivePrefix)
        invalid = Set(GameEditing.invalidFields(title: title, path: state.path, prefix: prefix))
        if !invalid.isEmpty {
            page = .general
            return
        }
        let isEdit = state.original != nil
        let all = (try? GamesStore(paths: model.paths).loadAll()) ?? model.games
        if !isEdit, GameEditing.titleExists(title, in: all) {
            warning = t.format("%s already exists", title)
            return
        }

        var draft = GameEditing.Draft()
        draft.title = title
        draft.path = state.path
        draft.prefix = prefix
        draft.customRunner = state.customRunner
        draft.runner = state.runner
        draft.graphics = state.graphics
        draft.launchArguments = state.launchArguments.map(\.text)
        draft.gameArguments = state.gameArguments
        draft.preLaunch = state.preLaunch
        draft.postLaunch = state.postLaunch
        draft.discordRPC = state.discordRPC
        draft.noSleep = state.noSleep
        draft.sdl = state.sdl
        draft.addAppEnabled = state.addAppEnabled
        draft.addAppPath = state.addAppPath
        draft.addAppDelay = state.addAppDelay
        draft.addAppFirst = state.addAppFirst
        let game = GameEditing.apply(
            draft, to: state.original ?? Game(gameID: suggestedID, title: title), paths: model.paths)

        do {
            try? PresetsStore(paths: model.paths).save(state.presets.map(\.text))
            if game.addAppEnabled { try GameEditing.writeAddAppBat(for: game, paths: model.paths) }
        } catch {
            warning = "\(error)"
            return
        }
        model.save(game)
        model.selection = game.gameID
        dismiss()
    }
}

private extension View {
    /// `mark_invalid_widget`: a red outline until the field is edited again.
    func invalidMark(_ on: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: on ? 1.5 : 0))
    }
}

/// The magnifying glass button next to path fields.
struct SearchButton: View {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: "magnifyingglass") }
    }
}
