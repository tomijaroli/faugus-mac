import AppKit
import FaugusCore
import SwiftUI

/// "<title> Logs" window: one tab per log file (upstream shows proton.log and umu.log; the
/// Mac equivalents are wine.log and faugus.log). Refreshes while the game runs.
@MainActor
enum LogsWindowController {
    private static var windows: [String: NSWindow] = [:]

    static func show(game: Game, model: AppModel) {
        if let existing = windows[game.gameID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let dir = model.paths.gameLogsDir(gameID: game.gameID)
        let view = LogsView(
            title: model.translator.format("%s Logs", game.title),
            directory: dir,
            translator: model.translator
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = model.translator.format("%s Logs", game.title)
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        windows[game.gameID] = window
        NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { windows[game.gameID] = nil }
            }
        window.makeKeyAndOrderFront(nil)
    }
}

struct LogsView: View {
    let title: String
    let directory: String
    let translator: Translator
    @State private var tab = "wine.log"
    @State private var contents: [String: String] = [:]

    private let files = ["wine.log", "faugus.log"]

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(files, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding([.top, .horizontal], 10)
            ScrollView {
                Text(contents[tab] ?? "")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button(translator("Clear Logs")) {
                    for f in files {
                        try? FileManager.default.removeItem(atPath: directory + "/" + f)
                    }
                    refresh()
                }
                Spacer()
                Button(translator("Close")) { NSApp.keyWindow?.close() }
            }
            .padding([.bottom, .horizontal], 10)
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        for f in files {
            let path = directory + "/" + f
            // Wine's debug log can reach hundreds of MB; show only the tail.
            contents[f] = Self.tail(path: path, maxBytes: 512 * 1024)
        }
    }

    static func tail(path: String, maxBytes: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
