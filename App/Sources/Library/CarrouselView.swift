import AppKit
import FaugusCore
import SwiftUI

/// Carrousel mode (`build_carrousel_widget`, `layout_carrousel_slot`): a fan of covers around
/// the selected game that slides on arrow keys, scrolling and clicks.
struct CarrouselView: View {
    let model: AppModel
    let games: [Game]
    let appearance: LibraryAppearance
    let actions: GameActions

    /// The target as an absolute index (it grows past the list, the game is `index mod games.count`).
    @State private var index = 0
    /// The animated position the slots are laid out from.
    @State private var position: Double = 0
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulator = 0.0
    @State private var lastScroll = Date.distantPast

    private var config: FaugusConfig {
        appearance.config
    }

    private var labels: Bool {
        config.bool("labels-enabled")
    }

    private var alignment: Alignment {
        switch config.string("grid-position", default: "Middle") {
        case "Top": .top
        case "Bottom": .bottom
        default: .center
        }
    }

    private var coverWidth: CGFloat {
        (230 * Double(model.coverSize) / 100).rounded(.down)
    }

    private var coverHeight: CGFloat {
        (coverWidth * 1.5).rounded(.down)
    }

    private var step: CGFloat {
        coverWidth + 20
    }

    private var crossSize: CGFloat {
        coverHeight + 50 + 140
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if config.bool("overview-enabled"), let selectedGame = model.selectedGame {
                    OverviewPanel(model: model, game: selectedGame, appearance: appearance, width: geometry.size.width)
                }
                CarrouselLayer(
                    position: position, games: games, model: model, appearance: appearance, actions: actions,
                    cover: CGSize(width: coverWidth, height: coverHeight), step: step, showsLabel: labels,
                    onTap: tapped
                )
                .frame(height: crossSize)
            }
            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: alignment)
        }
        .background { BannerBackdrop(model: model, game: model.selectedGame) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow: move(-1)
            case .rightArrow: move(1)
            case .return:
                if let game = centerGame {
                    model.play(game, withLogs: false)
                }
            default: return .ignored
            }
            return .handled
        }
        .onAppear {
            model.gamepadColumnCount = 1
            model.gamepadGridIsHorizontal = false
            syncToSelection(animated: false)
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: games.map(\.gameID)) { _, _ in syncToSelection(animated: false) }
        .onChange(of: model.selection) { _, newSelection in
            if newSelection != centerGame?.gameID {
                syncToSelection(animated: true)
            }
        }
    }

    // MARK: Movement

    private var centerGame: Game? {
        guard !games.isEmpty else { return nil }
        return games[Self.mod(index, games.count)]
    }

    static func mod(_ value: Int, _ modulus: Int) -> Int {
        ((value % modulus) + modulus) % modulus
    }

    private func move(_ delta: Int) {
        guard !games.isEmpty, delta != 0 else { return }
        index += delta
        model.selection = centerGame?.gameID
        withAnimation(.easeInOut(duration: 0.26)) { position = Double(index) }
    }

    /// Moves the fan so the selected game is in the centre (the nearest copy when it wraps).
    private func syncToSelection(animated: Bool) {
        guard !games.isEmpty else { return }
        let gameCount = games.count
        let target = model.selection.flatMap { id in games.firstIndex { $0.gameID == id } } ?? 0
        if model.selection == nil || model.selection != games[target].gameID {
            model.selection = games[target].gameID
        }
        // Pick the copy of `target` closest to where the fan is now.
        var delta = target - Self.mod(index, gameCount)
        if delta > gameCount / 2 {
            delta -= gameCount
        } else if delta < -gameCount / 2 {
            delta += gameCount
        }
        index += delta
        if animated {
            withAnimation(.easeInOut(duration: 0.26)) { position = Double(index) }
        } else {
            position = Double(index)
        }
    }

    private func tapped(offset: Int, double: Bool) {
        if offset != 0 {
            move(offset)
        } else if double, let game = centerGame {
            model.play(game, withLogs: false)
        }
    }

    // MARK: Scroll wheel

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, window.isKeyWindow, !model.showSettings else { return event }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0 else { return event }
            // One step per notch; a trackpad needs about 40 points of travel for a step.
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1
            if scrollAccumulator * delta < 0 {
                scrollAccumulator = 0
            }
            scrollAccumulator += delta / unit
            guard abs(scrollAccumulator) >= 1, Date().timeIntervalSince(lastScroll) > 0.04 else { return nil }
            let direction = scrollAccumulator > 0 ? -1 : 1
            scrollAccumulator = 0
            lastScroll = Date()
            move(direction)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        scrollMonitor = nil
    }
}

/// The slots, laid out from a fractional `position` so SwiftUI can animate between games.
private struct CarrouselLayer: View, Animatable {
    nonisolated(unsafe) var position: Double
    let games: [Game]
    let model: AppModel
    let appearance: LibraryAppearance
    let actions: GameActions
    let cover: CGSize
    let step: CGFloat
    let showsLabel: Bool
    let onTap: (_ offset: Int, _ double: Bool) -> Void

    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    /// `carrousel_scale_opacity`.
    static func scaleOpacity(_ offset: Double) -> (scale: Double, opacity: Double) {
        let anchors: [(Double, Double, Double)] = [
            (0, 1.05, 1),
            (1, 0.82, 0.75),
            (2, 0.62, 0.5),
            (3, 0.46, 0.25),
            (4, 0.3, 0),
        ]
        let distance = abs(offset)
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where distance <= upper.0 {
            let fraction = (distance - lower.0) / (upper.0 - lower.0)
            return (
                lower.1 + (upper.1 - lower.1) * fraction,
                lower.2 + (upper.2 - lower.2) * fraction
            )
        }
        return (anchors.last!.1, anchors.last!.2)
    }

    var body: some View {
        GeometryReader { geometry in
            let gameCount = games.count
            let maxRadius = min(3, gameCount / 2)
            let fittingCount = step > 0 ? Int((geometry.size.width / step - 1) / 2) : maxRadius
            let radius = maxRadius <= 1 ? maxRadius : max(1, min(maxRadius, fittingCount))
            let base = Int(position.rounded(.down))
            ZStack {
                if gameCount > 0 {
                    ForEach((base - 4) ... (base + 5), id: \.self) { slotIndex in
                        let offset = Double(slotIndex) - position
                        slot(slotIndex, offset: offset, radius: radius, gameCount: gameCount)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func slot(_ slotIndex: Int, offset: Double, radius: Int, gameCount: Int) -> some View {
        let distance = abs(offset)
        let (scale, baseOpacity) = Self.scaleOpacity(offset)
        let opacity = distance > Double(radius) ? baseOpacity * max(0, Double(radius) + 1 - distance) : baseOpacity
        let game = games[CarrouselView.mod(slotIndex, gameCount)]
        let current = distance < 0.5
        let glow = max(0, 1 - distance)
        if opacity > 0.001 {
            GameTile(
                model: model, game: game, appearance: appearance, mode: .covers,
                size: CGSize(width: cover.width, height: cover.height + (showsLabel ? 50 : 0)),
                showsLabel: showsLabel, selected: current
            )
            .shadow(color: .black.opacity(0.65), radius: 7, y: 6)
            .shadow(color: appearance.accent.opacity(glow * 0.5), radius: 14)
            .scaleEffect((scale * 400).rounded(.down) / 400 + 0.00125)
            .opacity(opacity)
            .offset(x: offset * step)
            .zIndex(-distance)
            .allowsHitTesting(distance <= Double(radius) + 0.5)
            .onTapGesture(count: 2) { onTap(Int(offset.rounded()), true) }
            .onTapGesture { onTap(Int(offset.rounded()), false) }
            .contextMenu { GameContextMenu(model: model, game: game, actions: actions) }
            .modifier(CustomOrderDrag(model: model, game: game))
        }
    }
}
