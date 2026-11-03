import AppKit
import FaugusCore
import SwiftUI

/// Port of upstream's `Settings` dialog. Options whose feature has not landed yet (tray,
/// autostart, Discord, gamepad, SteamGridDB, sounds, backup) are added with that feature, and
/// the Linux-only ones are dropped (see `docs/parity.md`).
struct SettingsView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var cfg: FaugusConfig
    @State private var envars: [String]
    @State private var newEnvar = ""
    @State private var original: FaugusConfig
    @State private var originalEnvars: [String]
    @State private var runners: [InstalledRunner] = []
    @State private var showRunnerManager = false
    @State private var confirmDiscard = false
    @State private var logsSize: Int64?
    @State private var prefixInvalid = false
    @State private var pendingTool: PrefixTool?
    @State private var toolsBusy = 0

    enum PrefixTool { case winecfg, run }

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        let c = model.config!
        let e = EnvarStore(paths: model.paths).load()
        _cfg = State(initialValue: c)
        _original = State(initialValue: c)
        _envars = State(initialValue: e)
        _originalEnvars = State(initialValue: e)
    }

    private var modified: Bool { cfg != original || envars != originalEnvars }
    private var mode: InterfaceMode { InterfaceMode(configValue: cfg.string("interface-mode")) }

    var body: some View {
        let t = model.translator
        VStack(spacing: 0) {
            TabView {
                general(t).tabItem { Text(t("General")) }
                interface(t).tabItem { Text(t("Interface")) }
            }
            .padding([.horizontal, .top], 12)

            Divider()
            HStack {
                Picker(t("Language"), selection: text("language")) {
                    ForEach(languageCodes, id: \.self) { Text(languageName($0)).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button(t("Cancel")) { cancel() }.keyboardShortcut(.cancelAction)
                Button(t("Ok")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!modified)
            }
            .padding(12)
        }
        .frame(width: 680, height: 600)
        .onChange(of: cfg) { _, new in model.previewConfig = new }
        .task {
            runners = model.installedRunners()
            logsSize = model.logsSize()
        }
        .sheet(isPresented: $showRunnerManager, onDismiss: { runners = model.installedRunners() }) {
            RunnerManagerView(model: model) { showRunnerManager = false }
        }
        .confirmationDialog(
            t("Do you want to save the changes?"),
            isPresented: Binding(get: { pendingTool != nil }, set: { if !$0 { pendingTool = nil } }),
            titleVisibility: .visible
        ) {
            Button(t("Yes")) { finishPendingTool(save: true) }
            Button(t("No"), role: .destructive) { finishPendingTool(save: false) }
        }
        .confirmationDialog(
            t("Do you want to save the changes?"), isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button(t("Yes")) { save() }
            Button(t("No"), role: .destructive) {
                model.discardSettingsPreview()
                dismiss()
            }
        }
    }

    // MARK: General

    private func general(_ t: Translator) -> some View {
        Form {
            Section(t("Default Prefixes Location")) {
                HStack {
                    TextField("", text: text("default-prefix"))
                        .labelsHidden()
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: prefixInvalid ? 1.5 : 0))
                        .help(t("The location where prefixes are created"))
                        .onChange(of: cfg.string("default-prefix")) { _, v in
                            if !v.isEmpty { prefixInvalid = false }
                        }
                    Button(t("Select a prefix location") + "…") { choosePrefixFolder(t) }
                }
            }

            Section(t("Default Prefix Tools")) {
                Picker(t("Default Runner"), selection: runnerBinding) {
                    ForEach(runnerChoices, id: \.self) { Text($0).tag($0) }
                }
                Button(t("Runner Manager")) { showRunnerManager = true }
                HStack {
                    Button("Winecfg") { startTool(.winecfg) }
                        .accessibilityIdentifier("settings-winecfg")
                    Button(t("Run")) { startTool(.run) }
                        .help(t("Run a file in the prefix"))
                        .accessibilityIdentifier("settings-run")
                    if toolsBusy > 0 { ProgressView().controlSize(.small) }
                }
                .disabled(toolsBusy > 0)
            }

            Section(t("Miscellaneous")) {
                Toggle(t("Auto-close"), isOn: flag("auto-close-on-launch"))
                    .help(t("Automatically closes the application when launching a game"))
                Toggle(t("Splash window"), isOn: flag("splash-window-enabled"))
                    .help(t("Displays a splash window with information about the runner and other required components when launching a game"))
                Toggle(t("Automatic updates"), isOn: flag("automatic-updates"))
                    .help(t("Checks for and updates the runner and other required components when launching a game"))
                Toggle(t("Categories"), isOn: flag("categories-enabled"))
                    .help(t("Displays a button to manage game categories"))
                Toggle(t("Sort"), isOn: flag("sort-enabled"))
                    .help(t("Displays a button to change the game sorting order"))
                Toggle(t("Hidden games"), isOn: flag("show-hidden"))
                    .help(t("Displays hidden games") + "\n" + t("Ctrl+H toggles hidden games"))
                Toggle("SDL", isOn: flag("sdl-enabled"))
                    .help(t("May fix gamepad issues with some games"))
                Toggle(t("No Sleep"), isOn: flag("no-sleep-enabled"))
                    .help(t("Prevents the system from suspending while gaming"))
            }

            Section(t("Global Environment Variables")) {
                ForEach(envars.indices, id: \.self) { i in
                    HStack {
                        TextField("", text: $envars[i]).labelsHidden().font(.body.monospaced())
                        Button { envars.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                TextField("", text: $newEnvar, prompt: Text("KEY=VALUE"))
                    .labelsHidden().font(.body.monospaced())
                    .onSubmit { commitNewEnvar() }
            }

            Section {
                Button(clearLogsLabel(t)) {
                    model.clearLogs()
                    logsSize = model.logsSize()
                }
                .disabled(logsSize == nil)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Interface

    private func interface(_ t: Translator) -> some View {
        let sgdb = cfg.bool("steamgriddb-enabled")
        return Form {
            Section {
                Picker(t("Interface Mode"), selection: text("interface-mode")) {
                    ForEach(InterfaceMode.allCases, id: \.rawValue) { Text(t($0.label)).tag($0.rawValue) }
                }
            }

            Section(t("Display")) {
                Toggle(t("Labels"), isOn: flag("labels-enabled"))
                    .disabled(!mode.supportsLabelsAndZoom)
                    .help(mode.supportsLabelsAndZoom ? t("Displays the game title below the cover") : t("Covers or Carrousel mode"))
                Toggle(t("Zoom"), isOn: flag("zoom-enabled"))
                    .disabled(!mode.supportsLabelsAndZoom)
                    .help(mode.supportsLabelsAndZoom ? t("Displays a zoom slider to adjust the size of games") : t("Covers or Carrousel mode"))
                Toggle(t("Banner"), isOn: flag("banner-enabled"))
                    .disabled(!mode.supportsBanner(steamGridDBEnabled: sgdb))
                    .help(t("Covers or Carrousel mode with SteamGridDB"))
                Toggle(t("Overview"), isOn: flag("overview-enabled"))
                    .disabled(!mode.supportsOverview)
                    .help(mode.supportsOverview
                        ? t("Displays a panel with the game title, categories, playtime, and last played date")
                        : t("Grid, Covers or Carrousel mode"))
                Toggle(t("Auto-hide"), isOn: flag("auto-hide-enabled"))
                    .disabled(!mode.supportsOverview)
                    .help(t("Automatically hides widgets"))
                Picker(t("Position"), selection: text("grid-position")) {
                    Text(t("Top")).tag("Top")
                    Text(t("Middle")).tag("Middle")
                    Text(t("Bottom")).tag("Bottom")
                }
                .disabled(!mode.supportsPosition)
                .help(t("Sets how games are positioned on the screen"))
                Picker(t("Orientation"), selection: text("grid-orientation")) {
                    Text(t("Vertical")).tag("Vertical")
                    Text(t("Horizontal")).tag("Horizontal")
                }
                .disabled(!mode.supportsOrientation)
                .help(t("Sets how games are scrolled through"))
                HStack {
                    Text(t(InterfaceMode.maxChildrenLabel(orientation: cfg.string("grid-orientation"))))
                    Spacer()
                    Stepper(value: maxChildren, in: 1...99) { Text("\(maxChildren.wrappedValue)").monospacedDigit() }
                        .disabled(!cfg.bool("grid-max-children-enabled"))
                    Toggle("", isOn: flag("grid-max-children-enabled")).labelsHidden()
                }
                .disabled(!mode.supportsMaxChildren)
                Picker(t("Startup Window Size"), selection: text("startup-window-size")) {
                    Text(t("Default size")).tag("None")
                    Text(t("Remember size")).tag("Remember")
                    Text(t("Maximized")).tag("Maximized")
                    Text(t("Fullscreen")).tag("Fullscreen")
                }
                .disabled(!mode.supportsStartupWindowSize)
                .help(t("Alt+Enter toggles fullscreen"))
            }

            Section(t("Colors")) {
                Picker(t("Color Scheme"), selection: text("interface-theme")) {
                    Text(t("Default")).tag("system")
                    Text(t("Light")).tag("light")
                    Text(t("Dark")).tag("dark")
                }
                colorRow(t("Accent Color"), mode: "accent-mode", color: "accent-color",
                    modes: [("system", t("Default")), ("custom", t("Custom"))])
                colorRow(t("Background Color"), mode: "background-mode", color: "background-color",
                    modes: [("default", t("Default")), ("accent", t("Accent color")),
                        ("dominant_color", t("Dominant color")), ("custom", t("Custom"))])
                colorRow(t("Overview Color"), mode: "overview-color-mode", color: "overview-color",
                    modes: [("default", t("Default")), ("accent", t("Accent color")),
                        ("dominant_color", t("Dominant color")), ("custom", t("Custom"))])
                    .disabled(!cfg.bool("overview-enabled") || !mode.supportsOverview)
                Picker(t("Widget Color"), selection: text("widget-color-mode")) {
                    Text(t("Default")).tag("default")
                    Text(t("Accent color")).tag("accent")
                    Text(t("Solid color")).tag("solid")
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
                .disabled(cfg.string(mode) != "custom")
        }
    }

    // MARK: Bindings

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { cfg.bool(key) }, set: { cfg.setValue(key, bool: $0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { cfg.string(key) }, set: { cfg.setValue(key, $0) })
    }

    private var maxChildren: Binding<Int> {
        Binding(
            get: { max(1, cfg.int("grid-max-children-per-line", default: 20)) },
            set: { cfg.setValue("grid-max-children-per-line", String($0)) })
    }

    private func colorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: {
                let c = ConfigColor(cfg.string(key)) ?? .fallback
                return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
            },
            set: { new in
                let ns = NSColor(new).usingColorSpace(.sRGB) ?? .black
                let c = ConfigColor(
                    red: Int((ns.redComponent * 255).rounded()), green: Int((ns.greenComponent * 255).rounded()),
                    blue: Int((ns.blueComponent * 255).rounded()))
                cfg.setValue(key, c.cssString)
            })
    }

    // MARK: Runner and language

    private var runnerChoices: [String] {
        var names = [FaugusConfig.defaultRunner] + runners.map(\.name)
        let current = cfg.defaultRunner
        if !current.isEmpty, !names.contains(current) { names.append(current) }
        return names
    }

    private var runnerBinding: Binding<String> {
        Binding(
            get: { cfg.defaultRunner.isEmpty ? FaugusConfig.defaultRunner : cfg.defaultRunner },
            set: { cfg.setValue("default-runner", $0) })
    }

    private var languageCodes: [String] {
        var codes = AppModel.languageCatalogs()?.selectableLanguages() ?? ["en_US"]
        let current = cfg.string("language")
        if !current.isEmpty, !codes.contains(current) { codes.append(current) }
        return codes
    }

    private func languageName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Actions

    private func clearLogsLabel(_ t: Translator) -> String {
        guard let size = logsSize else { return t("Clear Logs") }
        return t("Clear Logs (%s)").replacingOccurrences(of: "%s", with: LogsMaintenance.formatSize(size))
    }

    private func commitNewEnvar() {
        let line = newEnvar.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { envars.append(line) }
        newEnvar = ""
    }

    private func choosePrefixFolder(_ t: Translator) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = t("Select a prefix location")
        panel.directoryURL = URL(fileURLWithPath: model.paths.expand(cfg.string("default-prefix")))
        if panel.runModal() == .OK, let url = panel.url { cfg.setValue("default-prefix", url.path) }
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
        if modified { pendingTool = tool } else { launch(tool) }
    }

    private func finishPendingTool(save: Bool) {
        guard let tool = pendingTool else { return }
        pendingTool = nil
        if save {
            commitNewEnvar()
            if cfg.string("default-prefix").trimmingCharacters(in: .whitespaces).isEmpty {
                prefixInvalid = true
                return
            }
            model.saveSettings(cfg, envars: envars)
            original = cfg
            originalEnvars = envars
        } else {
            cfg = original
            envars = originalEnvars
        }
        launch(tool)
    }

    private func launch(_ tool: PrefixTool) {
        let t = model.translator
        switch tool {
        case .winecfg:
            runInDefaultPrefix("winecfg")
        case .run:
            guard let file = FilePicker.choose(message: t("Select a file to run in the prefix")) else { return }
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

    private func save() {
        commitNewEnvar()
        if cfg.string("default-prefix").trimmingCharacters(in: .whitespaces).isEmpty {
            prefixInvalid = true
            return
        }
        model.saveSettings(cfg, envars: envars)
        dismiss()
    }
}
