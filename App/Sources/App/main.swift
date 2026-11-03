import FaugusCore
import Foundation

/// One executable, many verbs (see LaunchMode). Helper modes never start the SwiftUI launcher.
let launchMode = LaunchMode.parse(Array(CommandLine.arguments.dropFirst()))

switch launchMode {
case .launcher:
    FaugusLauncherApp.main()
case let .runGame(id, logs, pre, post):
    RunnerMode.run(gameID: id, logs: logs, preLaunch: pre, postLaunch: post)
case let .runFile(path, target, logs, pre, post):
    RunnerMode.run(target: target, logs: logs, preLaunch: pre, postLaunch: post, runFile: path)
case let .invalid(message):
    FileHandle.standardError.write(Data("Faugus: \(message)\n".utf8))
    exit(2)
case .splash, .donate, .winetricksLog:
    // Upstream starts these as helper processes because GTK windows cannot share a process.
    // Here the runner draws its own splash and Winetricks has its own window; the upstream
    // donation prompt is not ported (docs/parity.md).
    FileHandle.standardError
        .write(Data("Faugus: \(launchMode) is built into the app and is not a separate mode\n".utf8))
    exit(64)
default:
    // Daemon, dialog and shortcut modes arrive in later phases (docs/parity.md).
    FileHandle.standardError.write(Data("Faugus: \(launchMode) is not implemented yet\n".utf8))
    exit(64)
}
