import FaugusCore
import SwiftUI

/// Upstream's context menu (`build_context_menu`): play/stop, edit, delete, duplicate, hide,
/// category submenu, locations and logs. "Run file in the prefix" arrives with the `--run` mode.
struct GameContextMenu: View {
    let model: AppModel
    let game: Game
    let actions: GameActions

    var body: some View {
        let t = model.translator
        let running = model.isRunning(game)
        Button(running ? t("Stop") : t("Play with logs")) { model.play(game, withLogs: true) }
        Button(t("Edit")) { actions.edit(game) }
        Button(t("Delete")) { actions.delete(game) }
        Button(t("Duplicate")) { model.duplicate(game) }
        Button(game.hidden ? t("Remove from hidden") : t("Hide")) { model.toggleHidden(game) }
        categoryMenu(t)
        Divider()
        Button(t("Open game location")) { model.revealGameLocation(game) }
            .disabled(model.paths.expand(game.path).isEmpty)
        Button(t("Open prefix location")) { model.revealPrefix(game) }
            .disabled(!FileManager.default.fileExists(atPath: model.paths.expand(game.prefix)))
        Button(t("Show logs")) { LogsWindowController.show(game: game, model: model) }
            .disabled(!model.hasLogs(game))
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
