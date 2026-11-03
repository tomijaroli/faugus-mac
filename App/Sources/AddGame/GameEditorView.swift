import AppKit
import FaugusCore
import SwiftUI

/// Draft for the Add / Edit dialog (Windows game type; the Steam type arrives later in P2).
struct GameEditorState: Identifiable {
    enum Kind: Hashable { case windows, steam }

    let id = UUID()
    var original: Game?
    var kind: Kind = .windows
    /// Steam type: the account whose games are listed ("" = all) and the chosen app id.
    var steamUser = ""
    var steamAppID = ""
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
    var artwork = EditorArtworkDraft()

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
        if game.runner == "Steam" {
            s.kind = .steam
            s.steamUser = game.steamUser
            s.steamAppID = game.path
        }
        s.title = game.title
        s.path = game.path
        s.prefix = game.prefix
        s.prefixEdited = true
        s.customRunner = !(game.runner.isEmpty || game.runner == "Default")
        s.runner = game.runner.isEmpty ? "Default" : game.runner
        s.graphics = game.graphics ?? .default
        s.launchArguments = LaunchArgumentsEditor.normalized(
            LaunchArgumentLines.split(game.launchArguments).map { ArgLine(text: $0) }
        )
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
    @State private var warningDetail: String?
    @State private var urlPrompt: ArtworkSlot?
    /// Prefixes created by "Run" / "Run an installer" in this dialog, offered for discard on Cancel.
    @State private var createdPrefixes: [String] = []
    @State private var discardPrompt = false
    @State private var runningFiles = 0
    @State private var winetricksTarget: WinetricksTarget?
    @State private var steamUsers: [SteamLibrary.User] = []
    @State private var steamGames: [SteamLibrary.InstalledGame] = []
    @State private var steamInvalid = false

    init(model: AppModel, state: GameEditorState, dismiss: @escaping () -> Void) {
        self.model = model
        _state = State(initialValue: state)
        self.dismiss = dismiss
    }

    private var defaultPrefixBase: String {
        model.paths
            .expand(model.config?.string("default-prefix", default: model.paths.prefixesDir) ?? model.paths.prefixesDir)
    }

    private var suggestedID: String {
        GameID.unique(base: GameID.format(title: state.title), existing: model.existingIDs())
    }

    private var effectivePrefix: String {
        if state.prefixEdited, !state.prefix.isEmpty {
            return state.prefix
        }
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
            if caps.dxmt {
                out.append(.dxmt)
            }
            if caps.d3dmetal {
                out.append(.d3dmetal)
            }
        }
        if !out.contains(state.graphics) {
            out.append(state.graphics)
        }
        return out
    }

    private func graphicsLabel(_ g: GraphicsBackend) -> String {
        switch g {
        case .default: model.translator("Default")
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        case .wined3dVulkan: "WineD3D (Vulkan)"
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        }
    }

    /// The runner a new game gets when "Specific Runner" is off: the configured default.
    private var runnerChoices: [String] {
        var names = [WineFlavor.staging.latestIdentifier] + model.installedRunners().map(\.name)
        if state.customRunner, state.runner != "Default", !names.contains(state.runner) {
            names.append(state.runner)
        }
        return names
    }

    var body: some View {
        let t = model.translator
        let isEdit = state.original != nil
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? t.format("Edit %s", state.original?.title ?? "") : t("New Game/App"))
                .font(.title2.weight(.semibold)).padding([.top, .horizontal], 20)
            if state.kind == .windows {
                Picker("", selection: $page) {
                    Text(t("General")).tag(Page.general)
                    Text(t("Settings")).tag(Page.settings)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 20).padding(.top, 12)
                .accessibilityIdentifier("editor-pages")
            }

            Group {
                switch page {
                case .general: general(t)
                case .settings: settings(t)
                }
            }
            .frame(minHeight: 360)

            HStack {
                if state.kind == .windows {
                    Button("Winetricks") { openWinetricks() }
                        .disabled(runningFiles > 0 || originalIsRunning)
                        .help(originalIsRunning ? t.format("%s is running", state.original?.title ?? "") : "")
                        .accessibilityIdentifier("editor-winetricks")
                    Button("Winecfg") { runWinecfg() }
                        .disabled(runningFiles > 0)
                        .accessibilityIdentifier("editor-winecfg")
                    Button(t("Run")) { runFileInPrefix() }
                        .help(t("Run a file in the prefix"))
                        .accessibilityIdentifier("editor-run")
                    if runningFiles > 0 {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer()
                Button(t("Cancel"), role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button(t("Confirm")) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editor-confirm")
            }
            .padding(20)
        }
        .frame(width: showsCover ? 800 : 600)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .alert(warning ?? "", isPresented: Binding(get: { warning != nil }, set: {
            if !$0 {
                warning = nil
                warningDetail = nil
            }
        })) {
            Button(t("Ok")) {}
        } message: {
            Text(warningDetail ?? "")
        }
        .alert(
            createdPrefixes
                .count > 1 ? t("Do you want to discard these prefixes?") : t("Do you want to discard this prefix?"),
            isPresented: $discardPrompt
        ) {
            Button(t("Yes"), role: .destructive) { discardCreatedPrefixes()
                dismiss()
            }
            Button(t("No"), role: .cancel) { dismiss() }
        } message: {
            Text(createdPrefixes.joined(separator: "\n"))
        }
        .sheet(item: $winetricksTarget) { target in
            WinetricksView(
                model: model, prefix: target.prefix, runnerName: runnerForRun, logName: logIDForRun,
                subtitle: target.prefix
            ) {
                winetricksTarget = nil
                recordCreatedPrefix(target.prefix, existedBefore: target.existedBefore)
            }
        }
        .sheet(item: $urlPrompt) { slot in
            ImageURLPrompt(t: t, slot: slot) { data in
                urlPrompt = nil
                if let data {
                    applyImage(data, to: slot)
                }
            }
        }
        .task { prepareArtwork()
            loadSteamUsers()
        }
        .task(id: state.kind == .steam ? state.steamUser : nil) { await loadSteamGames() }
        .onChange(of: state.kind) { _, _ in page = .general }
        .onDisappear { state.artwork.cleanUp() }
    }

    // MARK: General page

    private func general(_ t: Translator) -> some View {
        HStack(alignment: .top, spacing: 0) {
            generalForm(t)
            if showsCover {
                coverPanel(t).padding(.trailing, 20).padding(.top, 20)
            }
        }
    }

    private func generalForm(_ t: Translator) -> some View {
        Form {
            if !isEditing {
                Picker("Game type", selection: $state.kind) {
                    Text(t("Windows Game")).tag(GameEditorState.Kind.windows)
                    Text(t("Steam Game")).tag(GameEditorState.Kind.steam)
                }
                .labelsHidden()
                .accessibilityIdentifier("editor-game-type")
            }
            if state.kind == .steam {
                steamFields(t)
            } else {
                TextField(t("Title"), text: $state.title)
                    .invalidMark(invalid.contains(.title))
                    .accessibilityIdentifier("editor-title")
                HStack {
                    TextField(t("Path"), text: $state.path)
                        .invalidMark(invalid.contains(.path))
                        .help(t("Path to the game executable"))
                        .accessibilityIdentifier("editor-path")
                    Menu {
                        Button(t("Select an executable")) {
                            let dir = state.path.isEmpty ? nil : (model.paths.expand(state.path) as NSString)
                                .deletingLastPathComponent
                            if let p = FilePicker.choose(message: t("Select the game executable"), startIn: dir) {
                                fillFromExecutable(p)
                                state.path = p
                            }
                        }
                        Button(t("Run an installer")) { runInstaller() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(t("Select the game executable"))
                    .accessibilityIdentifier("editor-path-menu")
                }
                HStack {
                    TextField(t("Prefix"), text: Binding(
                        get: { state.prefixEdited ? state.prefix : effectivePrefix },
                        set: { state.prefix = $0
                            state.prefixEdited = true
                        }
                    ))
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
                Picker(
                    "Runner",
                    selection: Binding(
                        get: { state.customRunner ? state.runner : defaultRunnerChoice },
                        set: { state.runner = $0 }
                    )
                ) {
                    ForEach(runnerChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .disabled(!state.customRunner)
                Picker("Graphics", selection: $state.graphics) {
                    ForEach(graphicsChoices, id: \.self) { Text(graphicsLabel($0)).tag($0) }
                }
            }
            LabeledContent(t("Icon")) {
                ArtworkMenu(
                    t: t, hasImage: state.artwork.icon != nil,
                    loadFile: { loadFile(.icon) }, loadURL: { urlPrompt = .icon },
                    remove: { state.artwork.clear(.icon) }
                ) {
                    TempImage(path: state.artwork.icon, size: CGSize(width: 50, height: 50)) {
                        FaugusFallbackIcon()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("editor-icon")
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.title) { _, _ in invalid.remove(.title) }
        .onChange(of: state.path) { _, _ in invalid.remove(.path) }
        .onChange(of: state.prefix) { _, _ in invalid.remove(.prefix) }
        .onChange(of: state.customRunner) { _, custom in
            if !custom {
                state.runner = "Default"
            } else if state.runner == "Default" {
                state.runner = defaultRunnerChoice
            }
        }
    }

    private var isEditing: Bool {
        state.original != nil
    }

    // MARK: Steam type

    private func steamFields(_ t: Translator) -> some View {
        Group {
            Picker(t("Steam User"), selection: $state.steamUser) {
                if steamUsers.isEmpty {
                    Text("").tag("")
                }
                ForEach(steamUsers, id: \.accountID) { Text($0.label).tag($0.accountID) }
            }
            .disabled(steamUsers.isEmpty)
            .help(steamUsers.isEmpty ? t("No Steam users found") : "")
            .accessibilityIdentifier("editor-steam-user")
            Picker(t("Title"), selection: $state.steamAppID) {
                Text("").tag("")
                ForEach(steamChoices, id: \.appID) { Text($0.name).tag($0.appID) }
            }
            .invalidMark(steamInvalid)
            .disabled(steamUsers.isEmpty && !isEditing)
            .accessibilityIdentifier("editor-steam-title")
        }
        .onChange(of: state.steamAppID) { _, id in
            steamInvalid = false
            selectSteamGame(id)
        }
        .onChange(of: state.steamUser) { old, _ in
            // `cleanup_fields`: another account lists other games, so the choice is dropped.
            if !old.isEmpty, state.kind == .steam {
                clearSteamSelection()
            }
        }
    }

    /// The listed games, plus the edited game when it is no longer installed.
    private var steamChoices: [SteamLibrary.InstalledGame] {
        var out = steamGames
        if !state.steamAppID.isEmpty, !out.contains(where: { $0.appID == state.steamAppID }) {
            out.append(.init(appID: state.steamAppID, name: state.title))
        }
        return out
    }

    private func loadSteamUsers() {
        guard state.kind == .steam || !isEditing else { return }
        let steam = model.steam
        Task {
            let users = await Task.detached { steam.users() }.value
            steamUsers = users
            if !isEditing, state.steamUser.isEmpty, let first = users.first {
                state.steamUser = first.accountID
            }
            if isEditing, !state.steamUser.isEmpty, !users.contains(where: { $0.accountID == state.steamUser }) {
                steamUsers.append(.init(accountID: state.steamUser, name: state.steamUser))
            }
        }
    }

    private func loadSteamGames() async {
        guard state.kind == .steam else { return }
        let steam = model.steam
        let user = state.steamUser.isEmpty ? nil : state.steamUser
        steamGames = await Task.detached { steam.pickerGames(accountID: user) }.value
    }

    private func clearSteamSelection() {
        state.steamAppID = ""
        state.title = ""
        state.path = ""
        state.artwork.clear(.icon)
    }

    /// `on_combobox_steam_changed`: the title, the app id as the path, and Steam's own icon.
    private func selectSteamGame(_ appID: String) {
        guard !appID.isEmpty, let game = steamChoices.first(where: { $0.appID == appID }) else { return }
        state.title = game.name
        state.path = appID
        if let icon = model.steam.iconPath(appID: appID), let data = FileManager.default.contents(atPath: icon),
           state.artwork.setIcon(data: data)
        {
            return
        }
        state.artwork.clear(.icon)
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
                    if let p = FilePicker
                        .choose(message: t("Select a command or script"), startIn: state.preLaunch)
                    {
                        state.preLaunch = p
                    }
                }
            }
            HStack {
                TextField(t("Post-launch"), text: $state.postLaunch)
                    .help(t("Command or script to run after the game"))
                    .accessibilityIdentifier("editor-post-launch")
                SearchButton {
                    if let p = FilePicker
                        .choose(message: t("Select a command or script"), startIn: state.postLaunch)
                    {
                        state.postLaunch = p
                    }
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
                        if let p = FilePicker.choose(
                            message: t("Select an additional application"),
                            startIn: state.addAppPath
                        ) {
                            state.addAppPath = p
                        }
                    }
                }
                Stepper(value: $state.addAppDelay, in: 0 ... 60) {
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

    // MARK: Artwork

    private var showsCover: Bool {
        model.interfaceMode == .covers || model.interfaceMode == .carrousel
    }

    private func coverPanel(_ t: Translator) -> some View {
        ArtworkMenu(
            t: t, hasImage: state.artwork.cover != nil,
            loadFile: { loadFile(.cover) }, loadURL: { urlPrompt = .cover }, remove: { state.artwork.clear(.cover) }
        ) {
            TempImage(path: state.artwork.cover, size: CGSize(width: 200, height: 300), fill: true) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "plus").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("editor-cover")
    }

    /// The editor starts from the game's current cover and icon (copied, so Cancel changes nothing).
    private func prepareArtwork() {
        guard !state.artwork.prepared else { return }
        state.artwork.prepared = true
        guard let game = state.original else { return }
        let fm = FileManager.default
        let cover = model.paths.expand(game.cover)
        if !cover.isEmpty, let d = fm.contents(atPath: cover) {
            _ = state.artwork.setCover(data: d)
        }
        let icon = model.paths.expand(game.icon)
        if !icon.isEmpty, let d = fm.contents(atPath: icon) {
            _ = state.artwork.setIcon(data: d)
        }
    }

    private func loadFile(_ slot: ArtworkSlot) {
        let t = model.translator
        let message = slot == .cover ? t("Select an image for the cover") : t("Select an image for the icon")
        guard let path = FilePicker.chooseImage(message: message) else { return }
        guard let data = FileManager.default.contents(atPath: path),
              ImageTools.isValid(data) else { return invalidImage() }
        applyImage(data, to: slot)
    }

    private func applyImage(_ data: Data, to slot: ArtworkSlot) {
        let ok = slot == .cover ? state.artwork.setCover(data: data) : state.artwork.setIcon(data: data)
        if !ok {
            invalidImage()
        }
    }

    private func invalidImage() {
        let t = model.translator
        warning = t("The selected file is not a valid image.")
        warningDetail = t("Please choose another one.")
    }

    /// `fill_from_executable`: an empty title takes the executable's product name (or file
    /// name), and the executable's main icon replaces the icon.
    private func fillFromExecutable(_ path: String, fillTitle: Bool = true) {
        let hadTitle = !fillTitle || !state.title.trimmingCharacters(in: .whitespaces).isEmpty
        Task.detached {
            let info = GameArtwork.inspect(executable: path)
            await MainActor.run {
                if !hadTitle, state.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.title = info.title
                }
                if let png = info.iconPNG {
                    _ = state.artwork.setIcon(data: png)
                } else {
                    state.artwork.clear(.icon)
                }
            }
        }
    }

    // MARK: Run in the prefix

    /// The prefix the dialog would save, or nil (with a red mark) when there is none.
    private func prefixForRun() -> String? {
        let prefix = model.paths.expand(GameEditing.normalizedPath(effectivePrefix))
        if GameEditing.invalidFields(title: "x", path: "x", prefix: prefix).contains(.prefix) {
            invalid.insert(.prefix)
            return nil
        }
        return prefix
    }

    private var runnerForRun: String {
        state.customRunner ? state.runner : "Default"
    }

    private var logIDForRun: String {
        GameID.format(title: state.title)
    }

    /// Upstream records every prefix a run created, to offer discarding it on Cancel. A prefix
    /// that already existed is never recorded, so Cancel can never delete someone's old prefix.
    private func recordCreatedPrefix(_ prefix: String, existedBefore: Bool) {
        var isDir: ObjCBool = false
        guard !existedBefore, FileManager.default.fileExists(atPath: prefix, isDirectory: &isDir), isDir.boolValue,
              !createdPrefixes.contains(prefix)
        else { return }
        createdPrefixes.append(prefix)
    }

    /// "Run": any file (installer, `.reg`, tool) in the prefix.
    private func runFileInPrefix() {
        let t = model.translator
        guard let prefix = prefixForRun() else { return }
        guard let file = FilePicker.choose(message: t("Select a file to run in the prefix")) else { return }
        let existed = FileManager.default.fileExists(atPath: prefix)
        let (runner, logID) = (runnerForRun, logIDForRun)
        runningFiles += 1
        Task {
            _ = await model.runInPrefix(file: file, prefix: prefix, runner: runner, logID: logID)
            runningFiles -= 1
            recordCreatedPrefix(prefix, existedBefore: existed)
        }
    }

    struct WinetricksTarget: Identifiable {
        let id = UUID()
        let prefix: String
        let existedBefore: Bool
    }

    private var originalIsRunning: Bool {
        state.original.map { model.isRunning($0) } ?? false
    }

    /// "Winetricks" in the dialog's prefix and runner (upstream disables it while the game runs).
    private func openWinetricks() {
        guard let prefix = prefixForRun() else { return }
        winetricksTarget = WinetricksTarget(
            prefix: prefix,
            existedBefore: FileManager.default.fileExists(atPath: prefix)
        )
    }

    /// "Winecfg": Wine's configuration tool in the dialog's prefix and runner. The prefix is
    /// created if it does not exist yet, and recorded so Cancel can offer to discard it.
    private func runWinecfg() {
        guard let prefix = prefixForRun() else { return }
        let existed = FileManager.default.fileExists(atPath: prefix)
        let (runner, logID) = (runnerForRun, logIDForRun)
        runningFiles += 1
        Task {
            _ = await model.runInPrefix(file: "winecfg", prefix: prefix, runner: runner, logID: logID)
            runningFiles -= 1
            recordCreatedPrefix(prefix, existedBefore: existed)
        }
    }

    /// "Run an installer": runs it, then looks for the shortcut it created (10 tries, 2 s apart)
    /// and fills the Path with the installed executable.
    private func runInstaller() {
        let t = model.translator
        guard let prefix = prefixForRun() else { return }
        guard let file = FilePicker.choose(message: t("Select the game installer")) else { return }
        let existed = FileManager.default.fileExists(atPath: prefix)
        let (runner, logID) = (runnerForRun, logIDForRun)
        let before = InstalledExecutable.shortcuts(inPrefix: prefix)
        runningFiles += 1
        Task {
            _ = await model.runInPrefix(file: file, prefix: prefix, runner: runner, logID: logID)
            recordCreatedPrefix(prefix, existedBefore: existed)
            var detected: String?
            for attempt in 0 ..< 10 {
                detected = await Task.detached { InstalledExecutable.detect(prefix: prefix, existing: before) }.value
                if detected != nil || attempt == 9 {
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
            runningFiles -= 1
            if let detected {
                state.path = detected
                fillFromExecutable(detected, fillTitle: false)
            }
        }
    }

    private func cancel() {
        // Only prefixes no saved game uses are offered.
        let used = Set(model.games.map { model.paths.expand($0.prefix) })
        createdPrefixes.removeAll { used.contains($0) || !FileManager.default.fileExists(atPath: $0) }
        if createdPrefixes.isEmpty {
            dismiss()
        } else {
            discardPrompt = true
        }
    }

    /// Prefixes go to the Trash, never `rm` (plan section 8).
    private func discardCreatedPrefixes() {
        for prefix in createdPrefixes {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: prefix), resultingItemURL: nil)
        }
        createdPrefixes = []
    }

    // MARK: Save

    private func confirm() {
        let t = model.translator
        let title = state.title
        let prefix = GameEditing.normalizedPath(effectivePrefix)
        let isSteam = state.kind == .steam
        if isSteam, GameEditing.steamSelectionMissing(appID: state.steamAppID) {
            steamInvalid = true
            return
        }
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
        if isSteam {
            draft.steamUser = state.steamUser
        }
        let applied = GameEditing.apply(
            draft, to: state.original ?? Game(gameID: suggestedID, title: title), paths: model.paths
        )

        var game = applied
        let id = game.gameID
        if showsCover {
            game.cover = GameArtwork.saveCover(temp: state.artwork.cover, gameID: id, paths: model.paths)
        }
        game.icon = GameArtwork.saveIcon(temp: state.artwork.icon, gameID: id, paths: model.paths)

        do {
            try? PresetsStore(paths: model.paths).save(state.presets.map(\.text))
            if game.addAppEnabled, !isSteam {
                try GameEditing.writeAddAppBat(for: game, paths: model.paths)
            }
        } catch {
            warning = "\(error)"
            return
        }
        model.save(game)
        model.selection = game.gameID
        dismiss()
    }
}

extension View {
    /// `mark_invalid_widget`: a red outline until the field is edited again.
    fileprivate func invalidMark(_ on: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: on ? 1.5 : 0))
    }
}

/// The magnifying glass button next to path fields.
struct SearchButton: View {
    let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: "magnifyingglass") }
    }
}
