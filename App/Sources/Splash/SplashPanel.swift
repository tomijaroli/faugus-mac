import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SplashModel {
    var title = ""
    var status = ""
    /// `nil` shows an indeterminate spinner.
    var progress: Double?
    var image: NSImage?
}

/// The floating "starting game" window (upstream `FaugusSplash`). Closed once the game's own
/// window appears, or when the game ends.
@MainActor
final class SplashPanel {
    let model = SplashModel()
    private var panel: NSPanel?

    func show(iconPath: String?, fallbackIconPath: String?) {
        guard panel == nil else { return }
        if let iconPath, FileManager.default.fileExists(atPath: iconPath) {
            model.image = NSImage(contentsOfFile: iconPath)
        } else if let fallbackIconPath {
            model.image = NSImage(contentsOfFile: fallbackIconPath)
        }

        let host = NSHostingView(rootView: SplashView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = host
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    var isVisible: Bool {
        panel != nil
    }
}

private struct SplashView: View {
    let model: SplashModel

    var body: some View {
        VStack(spacing: 14) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(model.title).font(.title3.weight(.semibold)).lineLimit(1)
            Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center)
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: 260)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 420, height: 240)
    }
}
