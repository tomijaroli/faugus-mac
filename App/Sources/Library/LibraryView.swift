import FaugusCore
import SwiftUI

/// The main window: List, Grid, Covers and Carrousel modes with the toolbar of upstream's
/// bottom bar (zoom, add, settings, search, kill, play) plus the sort and category buttons.
struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var editor: GameEditorState?
    @State private var gameToDelete: Game?
    @State private var showCategories = false

    private var actions: GameActions {
        GameActions(
            edit: { editor = .edit($0, model: model) },
            delete: { gameToDelete = $0 })
    }

    var body: some View {
        let t = model.translator
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
        .toolbar { toolbar(t) }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: t("Search..."))
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
        .confirmationDialog(
            gameToDelete.map { t.format("Delete %s", $0.title) } ?? "",
            isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } }),
            presenting: gameToDelete
        ) { game in
            Button(t("Delete"), role: .destructive) { model.delete(game, removePrefix: false) }
            if FileManager.default.fileExists(atPath: model.paths.expand(game.prefix)) {
                Button(t("Also remove the prefix:"), role: .destructive) { model.delete(game, removePrefix: true) }
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: { game in
            Text(t.format("Are you sure you want to delete %s?", game.title))
        }
        .navigationTitle("Faugus")
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .onAppear { model.ensureSelection() }
        .onChange(of: model.visibleGames.map(\.gameID)) { _, _ in model.ensureSelection() }
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
        case .covers, .carrousel:
            GameGridView(model: model, games: games, appearance: appearance, mode: .covers, actions: actions)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ t: Translator) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if showsZoom {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Slider(value: zoomBinding, in: 50...100, step: 10).frame(width: 110)
                    Text("\(model.coverSize)").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                .help(t("Displays a zoom slider to adjust the size of games"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.sortEnabled { sortMenu(t) }
            if model.categoriesEnabled { categoryMenu(t) }
            Button(t("Add"), systemImage: "plus") { editor = .new(model: model) }
                .help(t("Add"))
            Button(t("Settings"), systemImage: "gearshape") { model.showSettings = true }
                .help(t("Settings"))
            Button(t("Kill all running games"), systemImage: "xmark.octagon") { model.killAll() }
                .help(t("Kill all running games"))
                .disabled(model.running.isEmpty)
            if let g = model.selectedGame {
                Button(
                    model.isRunning(g) ? t("Stop") : t("Play"),
                    systemImage: model.isRunning(g) ? "stop.fill" : "play.fill"
                ) { model.play(g, withLogs: false) }
                .help(model.isRunning(g) ? t("Stop") : t("Play"))
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

    private func sortMenu(_ t: Translator) -> some View {
        Menu {
            Picker(t("Sort"), selection: $model.sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text(t($0.label)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(t(model.sortMode.label))
        }
        .help(t("Displays a button to change the game sorting order"))
    }

    private func categoryMenu(_ t: Translator) -> some View {
        let entries: [CategorySelection] = [.all, .uncategorized] + model.categoryNames.map { .named($0) }
        return Menu {
            Picker(t("Categories"), selection: $model.category) {
                ForEach(entries, id: \.self) { entry in
                    Text("\(model.categoryLabel(entry)) (\(model.gameCount(in: entry)))").tag(entry)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(t("Manage categories...")) { showCategories = true }
        } label: {
            Text(model.categoryLabel(model.category))
        }
        .help(t("Displays a button to manage game categories"))
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
            if let id = ids.first, let g = model.games.first(where: { $0.gameID == id }) {
                model.play(g, withLogs: false)
            }
        }
        .accessibilityIdentifier("library-list")
    }
}

private struct GameRow: View {
    let game: Game
    let model: AppModel

    var body: some View {
        let t = model.translator
        HStack(spacing: 10) {
            ArtworkView(path: model.paths.expand(game.icon), size: CGSize(width: 40, height: 40)) {
                FaugusFallbackIcon()
            }
            .saturation(FileManager.default.fileExists(atPath: model.paths.expand(game.path)) ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.body).opacity(game.hidden ? 0.5 : 1)
                if let sub = subtitle(t) {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRunning(game) {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                    .help(t("Stop"))
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ t: Translator) -> String? {
        var parts: [String] = []
        if let p = GameFormatting.playtimeDisplay(seconds: game.playtime, t) {
            parts.append(t.format("Playtime: {}", p))
        }
        if model.isRunning(game) { return parts.joined(separator: " · ") }
        if let l = GameFormatting.lastPlayed(iso: game.lastPlayed, t) {
            parts.append(t.format("Last played: {}", l))
        } else if game.playtime == 0 {
            parts.append(t("Never played"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
