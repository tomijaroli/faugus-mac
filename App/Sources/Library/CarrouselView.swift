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

    /// The target as an absolute index (it grows past the list, the game is `index mod n`).
    @State private var index = 0
    /// The animated position the slots are laid out from.
    @State private var position: Double = 0
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulator = 0.0
    @State private var lastScroll = Date.distantPast

    private var config: FaugusConfig { appearance.config }
    private var labels: Bool { config.bool("labels-enabled") }

    private var alignment: Alignment {
        switch config.string("grid-position", default: "Middle") {
        case "Top": return .top
        case "Bottom": return .bottom
        default: return .center
        }
    }

    private var coverWidth: CGFloat { (230 * Double(model.coverSize) / 100).rounded(.down) }
    private var coverHeight: CGFloat { (coverWidth * 1.5).rounded(.down) }
    private var step: CGFloat { coverWidth + 20 }
    private var crossSize: CGFloat { coverHeight + 50 + 140 }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if config.bool("overview-enabled"), let g = model.selectedGame {
                    OverviewPanel(model: model, game: g, appearance: appearance, width: geo.size.width)
                }
                CarrouselLayer(
                    position: position, games: games, model: model, appearance: appearance, actions: actions,
                    cover: CGSize(width: coverWidth, height: coverHeight), step: step, showsLabel: labels,
                    onTap: tapped
                )
                .frame(height: crossSize)
            }
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: alignment)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow: move(-1)
            case .rightArrow: move(1)
            case .return:
                if let g = centerGame { model.play(g, withLogs: false) }
            default: return .ignored
            }
            return .handled
        }
        .onAppear {
            syncToSelection(animated: false)
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: games.map(\.gameID)) { _, _ in syncToSelection(animated: false) }
        .onChange(of: model.selection) { _, sel in
            if sel != centerGame?.gameID { syncToSelection(animated: true) }
        }
    }

    // MARK: Movement

    private var centerGame: Game? {
        guard !games.isEmpty else { return nil }
        return games[Self.mod(index, games.count)]
    }

    static func mod(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

    private func move(_ delta: Int) {
        guard !games.isEmpty, delta != 0 else { return }
        index += delta
        model.selection = centerGame?.gameID
        withAnimation(.easeInOut(duration: 0.26)) { position = Double(index) }
    }

    /// Moves the fan so the selected game is in the centre (the nearest copy when it wraps).
    private func syncToSelection(animated: Bool) {
        guard !games.isEmpty else { return }
        let n = games.count
        let target = model.selection.flatMap { id in games.firstIndex { $0.gameID == id } } ?? 0
        if model.selection == nil || model.selection != games[target].gameID { model.selection = games[target].gameID }
        // Pick the copy of `target` closest to where the fan is now.
        var delta = target - Self.mod(index, n)
        if delta > n / 2 { delta -= n } else if delta < -n / 2 { delta += n }
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
        } else if double, let g = centerGame {
            model.play(g, withLogs: false)
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
            if scrollAccumulator * delta < 0 { scrollAccumulator = 0 }
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
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
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
        let anchors: [(Double, Double, Double)] = [(0, 1.05, 1), (1, 0.82, 0.75), (2, 0.62, 0.5), (3, 0.46, 0.25), (4, 0.3, 0)]
        let d = abs(offset)
        for (a, b) in zip(anchors, anchors.dropFirst()) where d <= b.0 {
            let t = (d - a.0) / (b.0 - a.0)
            return (a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        return (anchors.last!.1, anchors.last!.2)
    }

    var body: some View {
        GeometryReader { geo in
            let n = games.count
            let maxRadius = min(3, n / 2)
            let fit = step > 0 ? Int((geo.size.width / step - 1) / 2) : maxRadius
            let radius = maxRadius <= 1 ? maxRadius : max(1, min(maxRadius, fit))
            let base = Int(position.rounded(.down))
            ZStack {
                if n > 0 {
                    ForEach((base - 4)...(base + 5), id: \.self) { i in
                        let offset = Double(i) - position
                        slot(i, offset: offset, radius: radius, n: n)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func slot(_ i: Int, offset: Double, radius: Int, n: Int) -> some View {
        let d = abs(offset)
        let (scale, baseOpacity) = Self.scaleOpacity(offset)
        let opacity = d > Double(radius) ? baseOpacity * max(0, Double(radius) + 1 - d) : baseOpacity
        let game = games[CarrouselView.mod(i, n)]
        let current = d < 0.5
        let glow = max(0, 1 - d)
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
            .zIndex(-d)
            .allowsHitTesting(d <= Double(radius) + 0.5)
            .onTapGesture(count: 2) { onTap(Int(offset.rounded()), true) }
            .onTapGesture { onTap(Int(offset.rounded()), false) }
            .contextMenu { GameContextMenu(model: model, game: game, actions: actions) }
            .modifier(CustomOrderDrag(model: model, game: game))
        }
    }
}
