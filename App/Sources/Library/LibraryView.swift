import FaugusCore
import SwiftUI

/// List mode (plan section 6: P1 ships list mode with the upstream context menu).
struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var selection: String?
    @State private var editor: GameEditorState?
    @State private var gameToDelete: Game?
    @Environment(\.openWindow) private var openWindow

    private var selectedGame: Game? { model.games.first { $0.gameID == selection } }

    var body: some View {
        let t = model.translator
        List(model.games, selection: $selection) { game in
            GameRow(game: game, model: model)
                .tag(game.gameID)
                .contextMenu { contextMenu(for: game) }
        }
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let g = model.games.first(where: { $0.gameID == id }) {
                model.play(g, withLogs: false)
            }
        }
        .overlay {
            if let error = model.loadError ?? model.actionError {
                Text(error).foregroundStyle(.red).padding()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(t("Add"), systemImage: "plus") { editor = .new(model: model) }
                    .help(t("Add"))
                if let g = selectedGame {
                    Button(
                        model.isRunning(g) ? t("Stop") : t("Play"),
                        systemImage: model.isRunning(g) ? "stop.fill" : "play.fill"
                    ) { model.play(g, withLogs: false) }
                    .help(model.isRunning(g) ? t("Stop") : t("Play"))
                }
                Button(t("Settings"), systemImage: "gearshape") { model.showSettings = true }
                    .help(t("Settings"))
            }
        }
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
        .accessibilityIdentifier("library-list")
    }

    /// Upstream's context menu: header, actions section (the Category submenu and "Run file in
    /// the prefix" arrive with P2/P3).
    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        let t = model.translator
        let running = model.isRunning(game)
        Button(running ? t("Stop") : t("Play with logs")) { model.play(game, withLogs: true) }
        Button(t("Edit")) { editor = .edit(game, model: model) }
        Button(t("Delete")) { gameToDelete = game }
        Button(t("Duplicate")) { model.duplicate(game) }
        Button(game.hidden ? t("Remove from hidden") : t("Hide")) { model.toggleHidden(game) }
        Divider()
        Button(t("Open game location")) { model.revealGameLocation(game) }
            .disabled(model.paths.expand(game.path).isEmpty)
        Button(t("Open prefix location")) { model.revealPrefix(game) }
            .disabled(!FileManager.default.fileExists(atPath: model.paths.expand(game.prefix)))
        Button(t("Show logs")) {
            LogsWindowController.show(game: game, model: model)
        }
        .disabled(!model.hasLogs(game))
    }
}

private struct GameRow: View {
    let game: Game
    let model: AppModel

    var body: some View {
        let t = model.translator
        HStack(spacing: 10) {
            GameIconView(path: model.paths.expand(game.icon))
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

private struct GameIconView: View {
    let path: String
    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "gamecontroller").resizable().scaledToFit().padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
