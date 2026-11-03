import FaugusCore
import SwiftUI

/// The SteamGridDB banner behind Covers and Carrousel when Settings "Banner" is on
/// (`banner_overlay_enabled` / `update_background`).
struct BannerBackdrop: View {
    let model: AppModel
    let game: Game?

    var body: some View {
        GeometryReader { geometry in
            if showsBanner, let path = bannerPath {
                ArtworkView(path: path, size: geometry.size, fill: true) { Color.clear }
                    .opacity(0.85)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.45),
                                .init(color: .white.opacity(0), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private var showsBanner: Bool {
        guard let configuration = model.activeConfig else { return false }
        return model.interfaceMode.supportsBanner(
            steamGridDBEnabled: configuration.bool("steamgriddb-enabled")
        ) && configuration.bool("banner-enabled")
    }

    private var bannerPath: String? {
        guard let game else { return nil }
        let path = model.paths.bannersDirectory + "/" + game.gameID + ".png"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
