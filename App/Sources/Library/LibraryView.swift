import FaugusCore
import SwiftUI

/// The main window: List, Grid, Covers and Carrousel modes with the toolbar of upstream's
/// bottom bar (zoom, add, settings, search, kill, play) plus the sort and category buttons.
struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var editor: GameEditorState?
    @State private var gameToDelete: Game?
    @State private var gameToDuplicate: Game?
    @State private var showCategories = false

    private var actions: GameActions {
        GameActions(
            edit: { editor = .edit($0, model: model) },
            delete: { gameToDelete = $0 },
            duplicate: { gameToDuplicate = $0 }
        )
    }

    var body: some View {
        let translate = model.translator
        Group {
            if let config = model.activeConfig {
                let appearance = LibraryAppearance(config: config, customAccent: model.accentColor)
                content(appearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LibraryBackground(appearance: appearance))
            } else {
                Text(model.loadError ?? "").foregroundStyle(.red).padding()
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.actionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding()
            }
        }
        .toolbar { toolbar(translate) }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: translate("Search..."))
        .sheet(item: $editor) { state in
            GameEditorView(model: model, state: state) { editor = nil }
        }
        .sheet(isPresented: $model.showSettings) {
            if model.config != nil {
                SettingsView(model: model) { model.showSettings = false }
            } else {
                RunnerManagerView(model: model) { model.showSettings = false }
            }
        }
        .sheet(isPresented: $showCategories) {
            CategoryManagerView(model: model) { showCategories = false }
        }
        .sheet(item: $gameToDelete) { game in
            DeleteGameView(model: model, game: game) { gameToDelete = nil }
        }
        .sheet(item: $gameToDuplicate) { game in
            DuplicateGameView(model: model, game: game) { gameToDuplicate = nil }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingShortcutFile != nil },
            set: {
                if !$0 {
                    model.pendingShortcutFile = nil
                }
            }
        )) {
            if let file = model.pendingShortcutFile {
                FileShortcutView(model: model, filePath: file) { model.pendingShortcutFile = nil }
            }
        }
        .navigationTitle("Faugus")
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .onAppear {
            model.ensureSelection()
            model.libraryActions = actions
        }
        .onChange(of: model.visibleGames.map(\.gameID)) { _, _ in model.ensureSelection() }
        .onChange(of: model.wantsNewGame) { _, wanted in
            if wanted {
                editor = .new(model: model)
                model.wantsNewGame = false
            }
        }
        .sheet(isPresented: Binding(
            get: { model.showGamepadOverlay },
            set: {
                if !$0 {
                    model.dismissGamepadOverlay()
                }
            }
        )) {
            GamepadListSheet(model: model) { model.dismissGamepadOverlay() }
        }
        .alert(
            model.runningGameWarning.map { model.translator.format("%s is running", $0) } ?? "",
            isPresented: Binding(
                get: { model.runningGameWarning != nil },
                set: {
                    if !$0 {
                        model.runningGameWarning = nil
                    }
                }
            )
        ) {
            Button(model.translator("Ok")) { model.runningGameWarning = nil }
        }
        .background(WindowConfigurator(model: model))
        .accessibilityIdentifier("library")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ appearance: LibraryAppearance) -> some View {
        let games = model.visibleGames
        switch model.interfaceMode {
        case .list:
            GameListView(model: model, games: games, appearance: appearance, actions: actions)
        case .grid:
            GameGridView(model: model, games: games, appearance: appearance, mode: .grid, actions: actions)
        case .covers:
            GameGridView(model: model, games: games, appearance: appearance, mode: .covers, actions: actions)
        case .carrousel:
            CarrouselView(model: model, games: games, appearance: appearance, actions: actions)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ translate: Translator) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if showsZoom {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Slider(value: zoomBinding, in: 50 ... 100, step: 10).frame(width: 110)
                    Text("\(model.coverSize)").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                .help(translate("Displays a zoom slider to adjust the size of games"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.sortEnabled {
                sortMenu(translate)
            }
            if model.categoriesEnabled {
                categoryMenu(translate)
            }
            Button(translate("Add"), systemImage: "plus") { editor = .new(model: model) }
                .help(translate("Add"))
            Button(translate("Settings"), systemImage: "gearshape") { model.showSettings = true }
                .help(translate("Settings"))
            Button(translate("Kill all running games"), systemImage: "xmark.octagon") { model.killAll() }
                .help(translate("Kill all running games"))
                .disabled(model.running.isEmpty)
            if let selectedGame = model.selectedGame {
                Button(
                    model.isRunning(selectedGame) ? translate("Stop") : translate("Play"),
                    systemImage: model.isRunning(selectedGame) ? "stop.fill" : "play.fill"
                ) { model.play(selectedGame, withLogs: false) }
                    .help(
                        selectedGame.needsAttention
                            ? translate("Needs attention")
                            : (model.isRunning(selectedGame) ? translate("Stop") : translate("Play"))
                    )
                    .disabled(!model.canPlay(selectedGame))
            }
        }
    }

    private var showsZoom: Bool {
        (model.interfaceMode == .covers || model.interfaceMode == .carrousel)
            && (model.activeConfig?.bool("zoom-enabled") ?? false)
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { Double(model.coverSize) }, set: { model.coverSize = Int(($0 / 10).rounded()) * 10 })
    }

    private func sortMenu(_ translate: Translator) -> some View {
        Menu {
            Picker(translate("Sort"), selection: $model.sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text(translate($0.label)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(translate(model.sortMode.label))
        }
        .help(translate("Displays a button to change the game sorting order"))
    }

    private func categoryMenu(_ translate: Translator) -> some View {
        let entries: [CategorySelection] = [.all, .uncategorized] + model.categoryNames.map { .named($0) }
        return Menu {
            Picker(translate("Categories"), selection: $model.category) {
                ForEach(entries, id: \.self) { entry in
                    Text("\(model.categoryLabel(entry)) (\(model.gameCount(in: entry)))").tag(entry)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(translate("Manage categories...")) { showCategories = true }
        } label: {
            Text(model.categoryLabel(model.category))
        }
        .help(translate("Displays a button to manage game categories"))
    }
}

/// List mode.
private struct GameListView: View {
    let model: AppModel
    let games: [Game]
    let appearance: LibraryAppearance
    let actions: GameActions

    var body: some View {
        List(games, selection: Binding(get: { model.selection }, set: { model.selection = $0 })) { game in
            GameRow(game: game, model: model)
                .tag(game.gameID)
                .contextMenu { GameContextMenu(model: model, game: game, actions: actions) }
                .modifier(CustomOrderDrag(model: model, game: game))
        }
        .scrollContentBackground(appearance.backgroundTint == nil ? .automatic : .hidden)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let game = model.games.first(where: { $0.gameID == id }) {
                model.play(game, withLogs: false)
            }
        }
        .accessibilityIdentifier("library-list")
        .onAppear {
            model.gamepadColumnCount = 1
            model.gamepadGridIsHorizontal = false
        }
    }
}

private struct GameRow: View {
    let game: Game
    let model: AppModel

    var body: some View {
        let translate = model.translator
        HStack(spacing: 10) {
            ArtworkView(path: model.paths.expand(game.icon), size: CGSize(width: 40, height: 40)) {
                FaugusFallbackIcon()
            }
            .saturation(FileManager.default.fileExists(atPath: model.paths.expand(game.path)) ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.body).opacity(game.hidden ? 0.5 : 1)
                if let subtitleText = subtitle(translate) {
                    Text(subtitleText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRunning(game) {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                    .help(translate("Stop"))
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ translate: Translator) -> String? {
        if game.needsAttention {
            return translate("Needs attention")
        }
        var parts: [String] = []
        if let playtime = GameFormatting.playtimeDisplay(seconds: model.playtimeSeconds(game), translate) {
            parts.append(translate.format("Playtime: {}", playtime))
        }
        if model.isRunning(game) {
            return parts.joined(separator: " · ")
        }
        if let lastPlayed = GameFormatting.lastPlayed(iso: game.lastPlayed, translate) {
            parts.append(translate.format("Last played: {}", lastPlayed))
        } else if model.playtimeSeconds(game) == 0 {
            parts.append(translate("Never played"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
