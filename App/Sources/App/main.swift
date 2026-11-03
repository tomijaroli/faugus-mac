import FaugusCore
import Foundation

/// One executable, many verbs (see LaunchMode). Helper modes never start the SwiftUI launcher.
let launchMode = LaunchMode.parse(Array(CommandLine.arguments.dropFirst()))

switch launchMode {
case let .launcher(_, _, file):
    if let file {
        // Upstream: a single positional argument runs the file in the default prefix and exits.
        let paths = FaugusPaths.live
        let configuration = try? FaugusConfig.load(paths: paths)
        let defaultPrefix = paths.expand(
            configuration?.string("default-prefix", default: paths.prefixesDirectory) ?? paths.prefixesDirectory
        )
        let runner = configuration?.string("default-runner") ?? ""
        let logID = GameID.format(
            title: ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        )
        RunnerMode.run(
            target: .prefix(path: defaultPrefix + "/default", runner: runner, logID: logID),
            logs: false,
            preLaunch: "",
            postLaunch: "",
            runFile: file
        )
    }
    if SingleInstance.handOverToRunningInstance() {
        exit(0)
    }
    FaugusLauncherApp.main()
case let .runGame(gameID, logs, preLaunch, postLaunch):
    RunnerMode.run(gameID: gameID, logs: logs, preLaunch: preLaunch, postLaunch: postLaunch)
case let .runFile(path, target, logs, preLaunch, postLaunch):
    RunnerMode.run(target: target, logs: logs, preLaunch: preLaunch, postLaunch: postLaunch, runFile: path)
case let .createShortcut(file):
    if SingleInstance.handOverToRunningInstance(shortcut: file) {
        exit(0)
    }
    FileShortcutMode.run(file: file)
case let .invalid(message):
    FileHandle.standardError.write(Data("Faugus: \(message)\n".utf8))
    exit(2)
case let .daemon(once):
    DaemonMode.run(once: once)
case .splash, .donate, .winetricksLog:
    // Upstream starts these as helper processes because GTK windows cannot share a process.
    // Here the runner draws its own splash and Winetricks has its own window; the upstream
    // donation prompt is not ported (docs/parity.md).
    FileHandle.standardError
        .write(Data("Faugus: \(launchMode) is built into the app and is not a separate mode\n".utf8))
    exit(64)
default:
    FileHandle.standardError.write(Data("Faugus: \(launchMode) is not implemented yet\n".utf8))
    exit(64)
}
