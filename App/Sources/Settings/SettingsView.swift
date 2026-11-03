import AppKit
import FaugusCore
import SwiftUI

/// Port of upstream's `Settings` dialog. Options whose feature has not landed yet (backup)
/// are added with that feature, and the Linux-only ones are dropped (see `docs/parity.md`).
struct SettingsView: View { // swiftlint:disable:this type_body_length
    let model: AppModel
    let dismiss: () -> Void

    @State private var configuration: FaugusConfig
    @State private var environmentVariables: [String]
    @State private var newEnvironmentVariable = ""
    @State private var original: FaugusConfig
    @State private var originalEnvironmentVariables: [String]
    @State private var runners: [InstalledRunner] = []
    @State private var showRunnerManager = false
    @State private var confirmDiscard = false
    @State private var logsSize: Int64?
    @State private var prefixInvalid = false
    @State private var steamGridDBKeyInvalid = false
    @State private var pendingTool: PrefixTool?
    @State private var toolsBusy = 0
    @State private var showWinetricks = false
    @State private var showInterfaceSounds = false

    enum PrefixTool { case winetricks, winecfg, run }

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        let initialConfiguration = model.config!
        let initialEnvironmentVariables = EnvironmentVariableStore(paths: model.paths).load()
        _configuration = State(initialValue: initialConfiguration)
        _original = State(initialValue: initialConfiguration)
        _environmentVariables = State(initialValue: initialEnvironmentVariables)
        _originalEnvironmentVariables = State(initialValue: initialEnvironmentVariables)
    }

    private var modified: Bool {
        configuration != original || environmentVariables != originalEnvironmentVariables
    }

    private var mode: InterfaceMode {
        InterfaceMode(configValue: configuration.string("interface-mode"))
    }

    var body: some View {
        let translate = model.translator
        VStack(spacing: 0) {
            TabView(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
                general(translate).tabItem { Text(translate("General")) }.tag(0)
                interface(translate).tabItem { Text(translate("Interface")) }.tag(1)
            }
            .padding([.horizontal, .top], 12)

            Divider()
            HStack {
                Picker(translate("Language"), selection: text("language")) {
                    ForEach(languageCodes, id: \.self) { Text(languageName($0)).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button(translate("Cancel")) { cancel() }.keyboardShortcut(.cancelAction)
                Button(translate("Ok")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!modified)
            }
            .padding(12)
        }
        .frame(width: 680, height: 600)
        .onChange(of: configuration) { _, newConfiguration in model.previewConfig = newConfiguration }
        .task {
            runners = model.installedRunners()
            logsSize = model.logsSize()
        }
        .sheet(isPresented: $showRunnerManager, onDismiss: { runners = model.installedRunners() }) {
            RunnerManagerView(model: model) { showRunnerManager = false }
        }
        .sheet(isPresented: $showInterfaceSounds) {
            InterfaceSoundsView(model: model, configuration: $configuration) { showInterfaceSounds = false }
        }
        .sheet(isPresented: $showWinetricks) {
            WinetricksView(
                model: model, prefix: model.defaultPrefixPath, runnerName: "Default", logName: "default",
                subtitle: model.defaultPrefixPath
            ) { showWinetricks = false }
        }
        .confirmationDialog(
            translate("Do you want to save the changes?"),
            isPresented: Binding(get: { pendingTool != nil }, set: {
                if !$0 {
                    pendingTool = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(translate("Yes")) { finishPendingTool(save: true) }
            Button(translate("No"), role: .destructive) { finishPendingTool(save: false) }
        }
        .confirmationDialog(
            translate("Do you want to save the changes?"), isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button(translate("Yes")) { save() }
            Button(translate("No"), role: .destructive) {
                model.discardSettingsPreview()
                dismiss()
            }
        }
    }

    // MARK: General

    // swiftlint:disable:next function_body_length
    private func general(_ translate: Translator) -> some View {
        Form {
            Section(translate("Default Prefixes Location")) {
                HStack {
                    TextField("", text: text("default-prefix"))
                        .labelsHidden()
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                            Color.red,
                            lineWidth: prefixInvalid ? 1.5 : 0
                        ))
                        .help(translate("The location where prefixes are created"))
                        .onChange(of: configuration.string("default-prefix")) { _, newPrefixLocation in
                            if !newPrefixLocation.isEmpty {
                                prefixInvalid = false
                            }
                        }
                    Button(translate("Select a prefix location") + "…") { choosePrefixFolder(translate) }
                }
            }

            Section(translate("Default Prefix Tools")) {
                Picker(translate("Default Runner"), selection: runnerBinding) {
                    ForEach(runnerChoices, id: \.self) { Text($0).tag($0) }
                }
                Button(translate("Runner Manager")) { showRunnerManager = true }
                HStack {
                    Button("Winetricks") { startTool(.winetricks) }
                        .accessibilityIdentifier("settings-winetricks")
                    Button("Winecfg") { startTool(.winecfg) }
                        .accessibilityIdentifier("settings-winecfg")
                    Button(translate("Run")) { startTool(.run) }
                        .help(translate("Run a file in the prefix"))
                        .accessibilityIdentifier("settings-run")
                    if toolsBusy > 0 {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(toolsBusy > 0)
            }

            Section(translate("Miscellaneous")) {
                Toggle(translate("Auto-close"), isOn: flag("auto-close-on-launch"))
                    .help(translate("Automatically closes the application when launching a game"))
                Toggle(translate("Splash window"), isOn: flag("splash-window-enabled"))
                    .help(
                        translate(
                            "Displays a splash window with information about the runner and other required "
                                + "components when launching a game"
                        )
                    )
                Toggle(translate("Automatic updates"), isOn: flag("automatic-updates"))
                    .help(
                        translate(
                            "Checks for and updates the runner and other required components when launching a game"
                        )
                    )
                Toggle(translate("Gamepad navigation"), isOn: flag("gamepad-navigation"))
                    .help(translate("Allows navigation through the application using a gamepad"))
                    .disabled(model.isConsoleMode)
                Toggle(translate("Autostart"), isOn: flag("autostart-enabled"))
                    .help(translate("Automatically starts the application with the system"))
                Toggle(translate("System tray icon"), isOn: flag("system-tray"))
                    .help(translate("Displays the application icon in the system tray"))
                Toggle(translate("Minimized startup"), isOn: flag("minimized-startup-enabled"))
                    .disabled(!configuration.bool("system-tray"))
                    .help(translate("Starts the application minimized to the system tray"))
                Toggle(translate("Monochrome icon"), isOn: flag("mono-icon"))
                    .disabled(!configuration.bool("system-tray"))
                    .help(translate("Displays a monochrome application icon in the system tray"))
                Toggle(translate("Categories"), isOn: flag("categories-enabled"))
                    .help(translate("Displays a button to manage game categories"))
                Toggle(translate("Sort"), isOn: flag("sort-enabled"))
                    .help(translate("Displays a button to change the game sorting order"))
                Toggle(translate("Hidden games"), isOn: flag("show-hidden"))
                    .help(translate("Displays hidden games") + "\n" + translate("Ctrl+H toggles hidden games"))
                Toggle("SDL", isOn: flag("sdl-enabled"))
                    .help(translate("May fix gamepad issues with some games"))
                Toggle(translate("No Sleep"), isOn: flag("no-sleep-enabled"))
                    .help(translate("Prevents the system from suspending while gaming"))
                Toggle("Discord RPC", isOn: flag("discord-rpc-enabled"))
                    .help(translate("Shows the running game as your Discord activity"))
            }

            Section(translate("Global Environment Variables")) {
                ForEach(environmentVariables.indices, id: \.self) { variableIndex in
                    HStack {
                        TextField("", text: $environmentVariables[variableIndex]).labelsHidden()
                            .font(.body.monospaced())
                        Button { environmentVariables.remove(at: variableIndex) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                TextField("", text: $newEnvironmentVariable, prompt: Text("KEY=VALUE"))
                    .labelsHidden().font(.body.monospaced())
                    .onSubmit { commitNewEnvironmentVariable() }
            }

            Section {
                Button(clearLogsLabel(translate)) {
                    model.clearLogs()
                    logsSize = model.logsSize()
                }
                .disabled(logsSize == nil)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Interface

    // swiftlint:disable:next function_body_length
    private func interface(_ translate: Translator) -> some View {
        let steamGridDBEnabled = configuration.bool("steamgriddb-enabled")
        return Form {
            Section {
                Picker(translate("Interface Mode"), selection: text("interface-mode")) {
                    ForEach(InterfaceMode.allCases, id: \.rawValue) { Text(translate($0.label)).tag($0.rawValue) }
                }
            }

            Section {
                Button(translate("Interface Sounds")) { showInterfaceSounds = true }
            }

            Section {
                Toggle("SteamGridDB", isOn: flag("steamgriddb-enabled"))
                    .help(translate("Automatically fetches game icons, covers, and banners from SteamGridDB"))
                HStack {
                    TextField("", text: text("steamgriddb-api-key"), prompt: Text(translate("API Key")))
                        .labelsHidden()
                        .disabled(!steamGridDBEnabled)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                            Color.red,
                            lineWidth: steamGridDBKeyInvalid ? 1.5 : 0
                        ))
                        .onChange(of: configuration.string("steamgriddb-api-key")) { _, newKey in
                            if !newKey.trimmingCharacters(in: .whitespaces).isEmpty {
                                steamGridDBKeyInvalid = false
                            }
                        }
                    Button {
                        if let url = URL(string: "https://www.steamgriddb.com/profile/preferences/api") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help(translate("Get an API key"))
                    .disabled(!steamGridDBEnabled)
                }
            }

            Section(translate("Display")) {
                Toggle(translate("Labels"), isOn: flag("labels-enabled"))
                    .disabled(!mode.supportsLabelsAndZoom)
                    .help(mode
                        .supportsLabelsAndZoom ? translate("Displays the game title below the cover") :
                        translate("Covers or Carrousel mode"))
                Toggle(translate("Zoom"), isOn: flag("zoom-enabled"))
                    .disabled(!mode.supportsLabelsAndZoom)
                    .help(mode
                        .supportsLabelsAndZoom ? translate("Displays a zoom slider to adjust the size of games") :
                        translate("Covers or Carrousel mode"))
                Toggle(translate("Banner"), isOn: flag("banner-enabled"))
                    .disabled(!mode.supportsBanner(steamGridDBEnabled: steamGridDBEnabled))
                    .help(translate("Covers or Carrousel mode with SteamGridDB"))
                Toggle(translate("Overview"), isOn: flag("overview-enabled"))
                    .disabled(!mode.supportsOverview)
                    .help(mode.supportsOverview
                        ? translate("Displays a panel with the game title, categories, playtime, and last played date")
                        : translate("Grid, Covers or Carrousel mode"))
                Toggle(translate("Auto-hide"), isOn: flag("auto-hide-enabled"))
                    .disabled(!mode.supportsOverview)
                    .help(translate("Automatically hides widgets"))
                Picker(translate("Position"), selection: text("grid-position")) {
                    Text(translate("Top")).tag("Top")
                    Text(translate("Middle")).tag("Middle")
                    Text(translate("Bottom")).tag("Bottom")
                }
                .disabled(!mode.supportsPosition)
                .help(translate("Sets how games are positioned on the screen"))
                Picker(translate("Orientation"), selection: text("grid-orientation")) {
                    Text(translate("Vertical")).tag("Vertical")
                    Text(translate("Horizontal")).tag("Horizontal")
                }
                .disabled(!mode.supportsOrientation)
                .help(translate("Sets how games are scrolled through"))
                HStack {
                    Text(translate(InterfaceMode
                            .maxChildrenLabel(orientation: configuration.string("grid-orientation"))))
                    Spacer()
                    Stepper(value: maxChildren, in: 1 ... 99) { Text("\(maxChildren.wrappedValue)").monospacedDigit() }
                        .disabled(!configuration.bool("grid-max-children-enabled"))
                    Toggle("", isOn: flag("grid-max-children-enabled")).labelsHidden()
                }
                .disabled(!mode.supportsMaxChildren)
                Picker(translate("Startup Window Size"), selection: text("startup-window-size")) {
                    Text(translate("Default size")).tag("None")
                    Text(translate("Remember size")).tag("Remember")
                    Text(translate("Maximized")).tag("Maximized")
                    Text(translate("Fullscreen")).tag("Fullscreen")
                }
                .disabled(!mode.supportsStartupWindowSize)
                .help(translate("Alt+Enter toggles fullscreen"))
            }

            Section(translate("Colors")) {
                Picker(translate("Color Scheme"), selection: text("interface-theme")) {
                    Text(translate("Default")).tag("system")
                    Text(translate("Light")).tag("light")
                    Text(translate("Dark")).tag("dark")
                }
                colorRow(
                    translate("Accent Color"),
                    mode: "accent-mode",
                    color: "accent-color",
                    modes: [("system", translate("Default")), ("custom", translate("Custom"))]
                )
                colorRow(
                    translate("Background Color"),
                    mode: "background-mode",
                    color: "background-color",
                    modes: [
                        ("default", translate("Default")),
                        ("accent", translate("Accent color")),
                        ("dominant_color", translate("Dominant color")),
                        ("custom", translate("Custom")),
                    ]
                )
                colorRow(
                    translate("Overview Color"),
                    mode: "overview-color-mode",
                    color: "overview-color",
                    modes: [
                        ("default", translate("Default")),
                        ("accent", translate("Accent color")),
                        ("dominant_color", translate("Dominant color")),
                        ("custom", translate("Custom")),
                    ]
                )
                .disabled(!configuration.bool("overview-enabled") || !mode.supportsOverview)
                Picker(translate("Widget Color"), selection: text("widget-color-mode")) {
                    Text(translate("Default")).tag("default")
                    Text(translate("Accent color")).tag("accent")
                    Text(translate("Solid color")).tag("solid")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, mode: String, color: String, modes: [(String, String)]) -> some View {
        HStack {
            Picker(title, selection: text(mode)) {
                ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
            }
            ColorPicker("", selection: colorBinding(color), supportsOpacity: false)
                .labelsHidden()
                .disabled(configuration.string(mode) != "custom")
        }
    }

    // MARK: Bindings

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { configuration.bool(key) }, set: { configuration.setValue(key, bool: $0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { configuration.string(key) }, set: { configuration.setValue(key, $0) })
    }

    private var maxChildren: Binding<Int> {
        Binding(
            get: { max(1, configuration.int("grid-max-children-per-line", default: 20)) },
            set: { configuration.setValue("grid-max-children-per-line", String($0)) }
        )
    }

    private func colorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: {
                let configColor = ConfigColor(configuration.string(key)) ?? .fallback
                return Color(
                    .sRGB,
                    red: Double(configColor.red) / 255,
                    green: Double(configColor.green) / 255,
                    blue: Double(configColor.blue) / 255
                )
            },
            set: { newColor in
                let nativeColor = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                let configColor = ConfigColor(
                    red: Int((nativeColor.redComponent * 255).rounded()),
                    green: Int((nativeColor.greenComponent * 255).rounded()),
                    blue: Int((nativeColor.blueComponent * 255).rounded())
                )
                configuration.setValue(key, configColor.cssString)
            }
        )
    }

    // MARK: Runner and language

    private var runnerChoices: [String] {
        var names = [FaugusConfig.defaultRunner] + runners.map(\.name)
        let current = configuration.defaultRunner
        if !current.isEmpty, !names.contains(current) {
            names.append(current)
        }
        return names
    }

    private var runnerBinding: Binding<String> {
        Binding(
            get: { configuration.defaultRunner.isEmpty ? FaugusConfig.defaultRunner : configuration.defaultRunner },
            set: { configuration.setValue("default-runner", $0) }
        )
    }

    private var languageCodes: [String] {
        var codes = AppModel.languageCatalogs()?.selectableLanguages() ?? ["en_US"]
        let current = configuration.string("language")
        if !current.isEmpty, !codes.contains(current) {
            codes.append(current)
        }
        return codes
    }

    private func languageName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Actions

    private func clearLogsLabel(_ translate: Translator) -> String {
        guard let size = logsSize else { return translate("Clear Logs") }
        return translate("Clear Logs (%s)").replacingOccurrences(of: "%s", with: LogsMaintenance.formatSize(size))
    }

    private func commitNewEnvironmentVariable() {
        let line = newEnvironmentVariable.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty {
            environmentVariables.append(line)
        }
        newEnvironmentVariable = ""
    }

    private func choosePrefixFolder(_ translate: Translator) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = translate("Select a prefix location")
        panel.directoryURL = URL(fileURLWithPath: model.paths.expand(configuration.string("default-prefix")))
        if panel.runModal() == .OK, let url = panel.url {
            configuration.setValue("default-prefix", url.path)
        }
    }

    private func cancel() {
        if modified {
            confirmDiscard = true
        } else {
            model.discardSettingsPreview()
            dismiss()
        }
    }

    // MARK: Default prefix tools

    /// Upstream's `check_modified`: unsaved changes are saved (or dropped) before the tool runs,
    /// because the tool uses the saved default prefix and runner.
    private func startTool(_ tool: PrefixTool) {
        if modified {
            pendingTool = tool
        } else {
            launch(tool)
        }
    }

    private func finishPendingTool(save: Bool) {
        guard let tool = pendingTool else { return }
        pendingTool = nil
        if save {
            commitNewEnvironmentVariable()
            guard validateConfiguration() else { return }
            model.saveSettings(configuration, environmentVariables: environmentVariables)
            original = configuration
            originalEnvironmentVariables = environmentVariables
        } else {
            configuration = original
            environmentVariables = originalEnvironmentVariables
        }
        launch(tool)
    }

    private func launch(_ tool: PrefixTool) {
        let translate = model.translator
        switch tool {
        case .winetricks:
            showWinetricks = true
        case .winecfg:
            runInDefaultPrefix("winecfg")
        case .run:
            guard let file = FilePicker.choose(message: translate("Select a file to run in the prefix")) else { return }
            runInDefaultPrefix(file)
        }
    }

    private func runInDefaultPrefix(_ file: String) {
        toolsBusy += 1
        Task {
            _ = await model.runInDefaultPrefix(file: file)
            toolsBusy -= 1
        }
    }

    /// Upstream's `validate_fields` for Settings: a prefix location, and an API key when SteamGridDB is on.
    private func validateConfiguration() -> Bool {
        var valid = true
        if configuration.string("default-prefix").trimmingCharacters(in: .whitespaces).isEmpty {
            prefixInvalid = true
            valid = false
        }
        if configuration.bool("steamgriddb-enabled"),
           configuration.string("steamgriddb-api-key").trimmingCharacters(in: .whitespaces).isEmpty
        {
            steamGridDBKeyInvalid = true
            valid = false
        }
        return valid
    }

    private func save() {
        commitNewEnvironmentVariable()
        guard validateConfiguration() else { return }
        model.saveSettings(configuration, environmentVariables: environmentVariables)
        dismiss()
    }
}
