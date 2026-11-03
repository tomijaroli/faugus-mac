import FaugusCore
import Foundation

// One executable, many verbs (see LaunchMode). Helper modes never start the SwiftUI launcher.
let launchMode = LaunchMode.parse(Array(CommandLine.arguments.dropFirst()))

switch launchMode {
case .launcher:
    FaugusLauncherApp.main()
case .runGame(let id, let logs, let pre, let post):
    RunnerMode.run(gameID: id, logs: logs, preLaunch: pre, postLaunch: post)
case .runFile(let path, let target, let logs, let pre, let post):
    RunnerMode.run(target: target, logs: logs, preLaunch: pre, postLaunch: post, runFile: path)
case .invalid(let message):
    FileHandle.standardError.write(Data("Faugus: \(message)\n".utf8))
    exit(2)
default:
    // Runner, daemon, splash and shortcut modes arrive in later phases (docs/parity.md).
    FileHandle.standardError.write(Data("Faugus: \(launchMode) is not implemented yet\n".utf8))
    exit(64)
}
