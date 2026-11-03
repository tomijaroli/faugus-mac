import AppKit
import FaugusCore
import SwiftUI

/// Upstream's `CreateShortcut` window (`faugus.shortcut` / `--shortcut <file>`): a stub `.app`
/// on the Desktop and in `~/Applications/Faugus` that runs the file in the default prefix.
struct FileShortcutView: View {
    let model: AppModel
    let filePath: String
    let dismiss: () -> Void

    @State private var title = ""
    @State private var titleInvalid = false
    @State private var gameArguments = ""
    @State private var preLaunch = ""
    @State private var postLaunch = ""
    @State private var sdlEnabled = false
    @State private var noSleepEnabled = false
    @State private var launchArguments: [ArgLine] = [ArgLine(text: "")]
    @State private var presets: [ArgLine] = [ArgLine(text: "")]
    @State private var iconPath: String?
    @State private var warning: String?
    @State private var page = Page.general

    enum Page: Hashable { case general, launchArguments }

    private var defaultPrefix: String {
        let base = model.paths.expand(
            model.config?.string("default-prefix", default: model.paths.prefixesDirectory)
                ?? model.paths.prefixesDirectory
        )
        return base + "/default"
    }

    private var defaultRunner: String {
        let configured = model.config?.string("default-runner") ?? ""
        return configured.isEmpty ? "Default" : configured
    }

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 0) {
            Text((filePath as NSString).lastPathComponent)
                .font(.title3.weight(.semibold))
                .padding([.top, .horizontal], 20)
            Picker("", selection: $page) {
                Text(translate("General")).tag(Page.general)
                Text(translate("Launch Arguments")).tag(Page.launchArguments)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 12)
            Group {
                switch page {
                case .general: general(translate)
                case .launchArguments:
                    LaunchArgumentsEditor(
                        translate: translate, arguments: $launchArguments, presets: $presets
                    )
                    .padding(20)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button(translate("Cancel"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(translate("Ok"), action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("shortcut-ok")
            }
            .padding(20)
        }
        .frame(width: 420)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .alert(warning ?? "", isPresented: Binding(get: { warning != nil }, set: {
            if !$0 {
                warning = nil
            }
        })) {
            Button(translate("Ok")) {}
        }
        .task { prepare() }
    }

    private func general(_ translate: Translator) -> some View {
        Form {
            TextField(translate("Title"), text: $title)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: titleInvalid ? 1.5 : 0))
                .onChange(of: title) { _, _ in titleInvalid = false }
                .accessibilityIdentifier("shortcut-title")
            TextField(translate("Game Arguments"), text: $gameArguments, prompt: Text("-d3d11 -fullscreen"))
            HStack {
                TextField(translate("Pre-launch"), text: $preLaunch)
                    .help(translate("Command or script to run before the game"))
                SearchButton {
                    if let scriptPath = FilePicker.choose(
                        message: translate("Select a command or script"), startIn: preLaunch
                    ) {
                        preLaunch = scriptPath
                    }
                }
            }
            HStack {
                TextField(translate("Post-launch"), text: $postLaunch)
                    .help(translate("Command or script to run after the game"))
                SearchButton {
                    if let scriptPath = FilePicker.choose(
                        message: translate("Select a command or script"), startIn: postLaunch
                    ) {
                        postLaunch = scriptPath
                    }
                }
            }
            Toggle("SDL", isOn: $sdlEnabled)
                .help(translate("May fix gamepad issues with some games"))
            Toggle(translate("No Sleep"), isOn: $noSleepEnabled)
                .help(translate("Prevents the system from suspending while gaming"))
            LabeledContent(translate("Icon")) {
                ArtworkMenu(
                    translate: translate, hasImage: iconPath != nil, showsLoadURL: false,
                    loadFile: { loadIconFile() },
                    remove: { iconPath = nil }
                ) {
                    TempImage(path: iconPath, size: CGSize(width: 50, height: 50)) {
                        FaugusFallbackIcon()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func prepare() {
        sdlEnabled = model.config?.bool("sdl-enabled") ?? false
        noSleepEnabled = model.config?.bool("no-sleep-enabled") ?? false
        presets = LaunchArgumentsEditor.normalized(PresetsStore(paths: model.paths).load().map { ArgLine(text: $0) })
        let fallback = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        Task.detached {
            let info = GameArtwork.inspect(executable: filePath)
            await MainActor.run {
                if title.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = info.title.isEmpty ? fallback : info.title
                }
                if let png = info.iconPNG {
                    applyIcon(png)
                }
            }
        }
    }

    private func loadIconFile() {
        let translate = model.translator
        guard let path = FilePicker.chooseImage(message: translate("Select an image for the icon")),
              let data = FileManager.default.contents(atPath: path)
        else { return }
        applyIcon(data)
    }

    private func applyIcon(_ data: Data) {
        guard let png = ImageTools.iconPNG(from: data, size: 256) else { return }
        let folder = model.paths.shortcutIconsDirectory
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/icon_temp.png"
        guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return }
        iconPath = path
    }

    private func confirm() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            titleInvalid = true
            page = .general
            return
        }
        try? PresetsStore(paths: model.paths).save(presets.map(\.text))
        var shortcut = FileShortcut(
            title: trimmed,
            executablePath: filePath,
            prefixPath: defaultPrefix,
            runnerName: defaultRunner
        )
        shortcut.gameArguments = gameArguments
        shortcut.launchArguments = launchArguments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        shortcut.preLaunch = preLaunch
        shortcut.postLaunch = postLaunch
        shortcut.sdlEnabled = sdlEnabled
        shortcut.noSleepEnabled = noSleepEnabled
        shortcut.iconPath = iconPath
        let library = ShortcutLibrary(
            paths: model.paths,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            fallbackIconPath: model.fallbackIconPath
        )
        do {
            _ = try shortcut.install(in: library)
            if let iconPath, iconPath.hasSuffix("/icon_temp.png") {
                let stored = model.paths.shortcutIconsDirectory + "/" + shortcut.shortcutID + ".png"
                try? FileManager.default.removeItem(atPath: stored)
                try? FileManager.default.moveItem(atPath: iconPath, toPath: stored)
            }
            dismiss()
        } catch {
            warning = "\(model.translator("Failed to create shortcut")): \(error)"
        }
    }
}

/// `--shortcut <file>` when no launcher is already running: a dedicated window, then exit.
enum FileShortcutMode {
    @MainActor
    static func run(file: String) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let model = AppModel()
        let root = FileShortcutView(model: model, filePath: file) {
            NSApp.terminate(nil)
        }
        .environment(\.locale, Locale(identifier: model.languageCode.replacingOccurrences(of: "_", with: "-")))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = (file as NSString).lastPathComponent
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            NSApp.terminate(nil)
        }
        application.run()
        exit(0)
    }
}
