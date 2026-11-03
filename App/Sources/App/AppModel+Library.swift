import AppKit
import FaugusCore
import Foundation

/// Library queries and actions: the visible list, categories, drag ordering, kill all.
extension AppModel {
    var noneLabel: String {
        translator("None")
    }

    var categoriesEnabled: Bool {
        activeConfig?.bool("categories-enabled") ?? false
    }

    var sortEnabled: Bool {
        activeConfig?.bool("sort-enabled") ?? false
    }

    var interfaceMode: InterfaceMode {
        InterfaceMode(configValue: activeConfig?.string("interface-mode") ?? "List")
    }

    /// Sorted and filtered like upstream's flowbox sort and filter functions.
    var visibleGames: [Game] {
        LibraryOrdering.visible(
            games, mode: sortMode, customOrder: customOrder, search: searchText.lowercased(),
            category: category, categoriesEnabled: categoriesEnabled, noneLabel: noneLabel
        )
    }

    var selectedGame: Game? {
        games.first { $0.gameID == selection }
    }

    /// Keeps the selection on a visible game, like `select_first_visible_child`.
    func ensureSelection() {
        let visible = visibleGames
        if let s = selection, visible.contains(where: { $0.gameID == s }) {
            return
        }
        selection = visible.first?.gameID
    }

    func categoryLabel(_ selection: CategorySelection) -> String {
        switch selection {
        case .all: translator("All")
        case .uncategorized: translator("Uncategorized")
        case let .named(n): n
        }
    }

    func gameCount(in selection: CategorySelection) -> Int {
        LibraryOrdering.count(games, in: selection, noneLabel: noneLabel)
    }

    // MARK: Categories

    var reservedCategoryNames: [String] {
        [translator("None"), translator("All"), translator("Uncategorized")]
    }

    /// The context-menu Category item.
    func toggleCategory(_ game: Game, _ name: String) {
        do {
            try CategoryAssignments(paths: paths).toggle(gameID: game.gameID, category: name, noneLabel: noneLabel)
            actionError = nil
        } catch { actionError = "\(error)" }
        reload()
    }

    @discardableResult
    func addCategory(_ name: String) -> CategoryStore.Failure? {
        do { _ = try CategoryStore(paths: paths).add(name, reserved: reservedCategoryNames)
        } catch let f as CategoryStore.Failure {
            return f
        } catch { actionError = "\(error)" }
        categoryNames = CategoryStore(paths: paths).load()
        return nil
    }

    @discardableResult
    func renameCategory(_ old: String, to new: String) -> CategoryStore.Failure? {
        do { _ = try CategoryStore(paths: paths).rename(old, to: new, reserved: reservedCategoryNames)
        } catch let f as CategoryStore.Failure {
            return f
        } catch { actionError = "\(error)" }
        if category == .named(old) {
            category = .named(new.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        reload()
        return nil
    }

    @discardableResult
    func removeCategory(_ name: String) -> CategoryStore.Failure? {
        do { _ = try CategoryStore(paths: paths).remove(name) } catch let f as CategoryStore.Failure {
            return f
        } catch { actionError = "\(error)" }
        if category == .named(name) {
            category = .all
        }
        reload()
        return nil
    }

    // MARK: Custom order

    /// Live reordering while a game is dragged over another one (custom sort only).
    func dragEntered(target: String) {
        guard sortMode == .custom, let source = dragSourceID, source != target else { return }
        let ordered = LibraryOrdering.sorted(games, mode: .custom, customOrder: customOrder).map(\.gameID)
        guard let moved = CustomOrderStore.move(ordered: ordered, source: source, target: target) else { return }
        customOrder.merge(moved) { _, new in new }
    }

    func dragEnded() {
        dragSourceID = nil
        guard sortMode == .custom else { return }
        try? CustomOrderStore(paths: paths).save(customOrder)
    }

    // MARK: Running games

    /// `get_play_session`: when the running game started and its playtime before the session.
    func playSession(for game: Game) -> (start: Date?, baseline: Int)? {
        guard let pid = running[game.gameID] else {
            playSessions[game.gameID] = nil
            return nil
        }
        if let s = playSessions[game.gameID] {
            return s
        }
        let session = (start: ProcessScanner.startDate(of: pid), baseline: game.playtime)
        playSessions[game.gameID] = session
        return session
    }

    /// "Kill all running games": a stop request for every running game.
    func killAll() {
        for id in running.keys {
            try? RunningGames(paths: paths).requestStop(gameID: id)
        }
    }
}
