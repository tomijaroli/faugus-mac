import AppKit
import FaugusCore
import SwiftUI

/// Applies `startup-window-size` (Default, Remember, Maximized, Fullscreen) the first time the
/// main window appears and records the size on resize when "Remember" is chosen. List mode
/// keeps the default size, like upstream.
struct WindowConfigurator: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) { nsView.model = model }

    final class ConfiguratorView: NSView {
        weak var model: AppModel?
        private var applied = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            guard let window, !applied else { return }
            applied = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(to: window)
                self.observe(window)
            }
        }

        @MainActor private func apply(to window: NSWindow) {
            guard let cfg = model?.config, InterfaceMode(configValue: cfg.string("interface-mode")) != .list else { return }
            switch cfg.string("startup-window-size") {
            case "Remember":
                let w = CGFloat(cfg.int("width", default: 1280)), h = CGFloat(cfg.int("height", default: 720))
                if w >= 480, h >= 320 { window.setContentSize(NSSize(width: w, height: h)) }
            case "Maximized":
                if !window.isZoomed { window.zoom(nil) }
            case "Fullscreen":
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            default: break
            }
        }

        @MainActor private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                        MainActor.assumeIsolated {
                            guard let self, let window else { return }
                            self.saveSize(of: window)
                        }
                    })
            }
        }

        @MainActor private func saveSize(of window: NSWindow) {
            guard let model, model.config?.string("startup-window-size") == "Remember",
                model.interfaceMode != .list, !window.styleMask.contains(.fullScreen), !window.isZoomed
            else { return }
            let size = window.contentLayoutRect.size
            model.updateConfig {
                $0.setValue("width", String(Int(size.width)))
                $0.setValue("height", String(Int(size.height)))
            }
        }
    }
}
