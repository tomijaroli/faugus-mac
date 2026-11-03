import FaugusCore
import SwiftUI
import UniformTypeIdentifiers

/// What a library view can ask the window to do.
struct GameActions {
    var edit: (Game) -> Void
    var delete: (Game) -> Void
    var duplicate: (Game) -> Void
}

/// Grid and Covers modes (`add_item_list`, `apply_flowbox_layout`, `arrange_main_content`).
struct GameGridView: View {
    let model: AppModel
    let games: [Game]
    let appearance: LibraryAppearance
    let mode: InterfaceMode
    let actions: GameActions

    @State private var viewport: CGSize = .zero

    private var config: FaugusConfig {
        appearance.config
    }

    private var horizontal: Bool {
        config.string("grid-orientation") == "Horizontal"
    }

    private var labels: Bool {
        mode == .grid || config.bool("labels-enabled")
    }

    private var maxChildren: Int {
        config.bool("grid-max-children-enabled") ? max(1, config.int("grid-max-children-per-line", default: 20)) : 20
    }

    private var tile: CGSize {
        switch mode {
        case .covers:
            let w = (230 * Double(model.coverSize) / 100).rounded(.down)
            return CGSize(width: w, height: (w * 1.5).rounded(.down) + (labels ? 50 : 0))
        default:
            return CGSize(width: 200, height: 170)
        }
    }

    private let spacing: CGFloat = 10
    private var inset: CGFloat {
        mode == .covers ? 40 : 10
    }

    private var alignment: Alignment {
        switch config.string("grid-position", default: "Middle") {
        case "Top": .top
        case "Bottom": .bottom
        default: .center
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(horizontal ? .horizontal : .vertical) {
                    VStack(spacing: 0) {
                        if config.bool("overview-enabled"), let g = model.selectedGame {
                            OverviewPanel(model: model, game: g, appearance: appearance, width: geo.size.width)
                        }
                        grid
                    }
                    .frame(
                        minWidth: horizontal ? nil : geo.size.width,
                        minHeight: geo.size.height, alignment: alignment
                    )
                }
                .onChange(of: model.selection) { _, id in
                    if let id {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
            .onAppear { viewport = geo.size }
            .onChange(of: geo.size) { _, new in viewport = new }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
    }

    /// Items per row (per column when scrolling horizontally), as many as fit up to the maximum,
    /// and no more than there are games so the group stays centred (the flowbox shrinks to fit).
    private var lanes: Int {
        let available = horizontal ? viewport.height : viewport.width
        let cell = (horizontal ? tile.height : tile.width) + spacing
        let fit = Int((available - inset * 2 + spacing) / cell)
        return max(1, min(maxChildren, fit, max(1, games.count)))
    }

    @ViewBuilder
    private var grid: some View {
        let items = Array(
            repeating: GridItem(.fixed(horizontal ? tile.height : tile.width), spacing: spacing),
            count: lanes
        )
        if horizontal {
            LazyHGrid(rows: items, spacing: spacing) { tiles }.padding(inset)
        } else {
            LazyVGrid(columns: items, spacing: spacing) { tiles }.padding(inset)
        }
    }

    private var tiles: some View {
        ForEach(games) { game in
            GameTile(
                model: model, game: game, appearance: appearance, mode: mode, size: tile, showsLabel: labels,
                selected: model.selection == game.gameID
            )
            .id(game.gameID)
            .onTapGesture(count: 2) {
                model.selection = game.gameID
                model.play(game, withLogs: false)
            }
            .onTapGesture { model.selection = game.gameID }
            .contextMenu { GameContextMenu(model: model, game: game, actions: actions) }
            .modifier(CustomOrderDrag(model: model, game: game))
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let current = games.firstIndex(where: { $0.gameID == model.selection }) else {
            if let first = games.first {
                model.selection = first.gameID
                return .handled
            }
            return .ignored
        }
        let cross = lanes
        let step: Int
        switch press.key {
        case .leftArrow: step = horizontal ? -cross : -1
        case .rightArrow: step = horizontal ? cross : 1
        case .upArrow: step = horizontal ? -1 : -cross
        case .downArrow: step = horizontal ? 1 : cross
        case .return:
            model.play(games[current], withLogs: false)
            return .handled
        default: return .ignored
        }
        let next = min(max(current + step, 0), games.count - 1)
        model.selection = games[next].gameID
        return .handled
    }
}

/// One game in Grid or Covers mode.
struct GameTile: View {
    let model: AppModel
    let game: Game
    let appearance: LibraryAppearance
    let mode: InterfaceMode
    let size: CGSize
    let showsLabel: Bool
    let selected: Bool

    private var installed: Bool {
        model.isInstalled(game)
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .covers {
                ArtworkView(
                    path: model.paths.expand(game.cover), size: CGSize(
                        width: size.width,
                        height: (size.width * 1.5).rounded(.down)
                    ),
                    fill: true
                ) {
                    appearance.placeholder
                }
                .saturation(installed ? 1 : 0)
            } else {
                ArtworkView(path: model.paths.expand(game.icon), size: CGSize(width: 100, height: 100)) {
                    FaugusFallbackIcon()
                }
                .saturation(installed ? 1 : 0)
                .padding(.top, 10)
            }
            if showsLabel {
                Text(game.title)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 10)
                    .frame(height: mode == .covers ? 50 : 60)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(appearance.tileBackground(selected: selected), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if model.isRunning(game) {
                Image(systemName: "play.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .padding(6)
            }
        }
        .opacity(game.hidden ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(game.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Faugus's own icon, shown where a game has none (`FAUGUS_PNG`).
struct FaugusFallbackIcon: View {
    var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/faugus-launcher-raster.png"),
           let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "gamecontroller").resizable().scaledToFit().padding(20).foregroundStyle(.secondary)
        }
    }
}

/// Drag to reorder, active only with the Custom sort (`setup_dnd_for_widget`).
struct CustomOrderDrag: ViewModifier {
    let model: AppModel
    let game: Game

    func body(content: Content) -> some View {
        if model.sortMode == .custom {
            content
                .onDrag {
                    model.dragSourceID = game.gameID
                    model.selection = game.gameID
                    return NSItemProvider(object: game.gameID as NSString)
                }
                .onDrop(of: [.text], delegate: OrderDropDelegate(model: model, targetID: game.gameID))
        } else {
            content
        }
    }
}

private struct OrderDropDelegate: DropDelegate {
    let model: AppModel
    let targetID: String

    func dropEntered(info _: DropInfo) {
        model.dragEntered(target: targetID)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        model.dragEnded()
        return true
    }
}
