import FaugusCore
import SwiftUI

struct FaugusLauncherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Faugus", id: "main") {
            LibraryView(model: model)
                .frame(minWidth: 480, minHeight: 320)
                .tint(model.accentColor.map {
                    Color(.sRGB, red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255)
                })
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(model.translator("Settings") + "…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(model.translator("About")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Unofficial macOS port of Faugus Launcher by Felix Ribeiro. Tracks upstream 2.5.6. Not affiliated."),
                    ])
                }
            }
        }
    }
}
