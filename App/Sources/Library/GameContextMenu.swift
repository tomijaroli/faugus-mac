import FaugusCore
import SwiftUI

/// Upstream's context menu (`build_context_menu`): play/stop, edit, delete, duplicate, hide,
/// category submenu, "Run file in the prefix" with recent files, locations and logs.
struct GameContextMenu: View {
    let model: AppModel
    let game: Game
    let actions: GameActions

    var body: some View {
        let t = model.translator
        let running = model.isRunning(game)
        let supportsLogs = game.runner != "Steam" && game.runner != "Linux-Native"
        Button(running ? t("Stop") : supportsLogs ? t("Play with logs") : t("Play")) {
            model.play(game, withLogs: supportsLogs)
        }
        Button(t("Edit")) { actions.edit(game) }
        Button(t("Delete")) { actions.delete(game) }
        if game.runner != "Steam" {
            Button(t("Duplicate")) { actions.duplicate(game) }
        }
        Button(game.hidden ? t("Remove from hidden") : t("Hide")) { model.toggleHidden(game) }
        categoryMenu(t)
        Divider()
        Button(t("Open game location")) { model.revealGameLocation(game) }
            .disabled(model.gameLocation(game) == nil)
        if game.runner != "Linux-Native" {
            Button(t("Open prefix location")) { model.revealPrefix(game) }
                .disabled(model.prefixLocation(game) == nil)
        }
        if supportsLogs {
            Button(t("Show logs")) { LogsWindowController.show(game: game, model: model) }
                .disabled(!model.hasLogs(game))
        }
        runFileMenu(t)
    }

    /// Upstream's run section: only for games that support logs (not Steam / Linux-Native).
    @ViewBuilder
    private func runFileMenu(_ t: Translator) -> some View {
        if game.runner != "Steam", game.runner != "Linux-Native" {
            let recent = model.recentRunFiles(for: game)
            Divider()
            Button(t("Run file in the prefix")) {
                if let file = FilePicker.choose(message: t("Select a file to run in the prefix")) {
                    model.runFile(file, in: game)
                }
            }
            if !recent.isEmpty {
                Menu(t("Recent")) {
                    ForEach(recent, id: \.self) { file in
                        Button((file as NSString).lastPathComponent) { model.runFile(file, in: game) }
                    }
                    Divider()
                    Button(t("Clear recent")) { model.clearRecentRunFiles(for: game) }
                }
            }
        }
    }

    private func categoryMenu(_ t: Translator) -> some View {
        let none = t("None")
        let names = [none] + model.categoryNames.sorted { $0.lowercased() < $1.lowercased() }
        let current = game.categoryNames.isEmpty ? [none] : game.categoryNames
        return Menu(t("Category")) {
            ForEach(names, id: \.self) { name in
                Button {
                    model.toggleCategory(game, name)
                } label: {
                    if current.contains(name) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
    }
}
