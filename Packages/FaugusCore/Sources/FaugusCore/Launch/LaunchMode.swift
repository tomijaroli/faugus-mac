import Foundation

/// What the single `Faugus` binary should do, decided from its command line.
///
/// Upstream 2.5.6 spreads these over several entry points; the Mac port folds them into one
/// executable (plan section 3) and keeps the same verbs:
///
/// | Upstream entry                          | Verb here                                   |
/// | --------------------------------------- | ------------------------------------------- |
/// | `faugus-launcher [--hide] [--console]`  | no verb (+ `--hide`, `--console`)           |
/// | `faugus-launcher <file>`                | one positional file                         |
/// | `faugus.runner --game <id> [--logs]`    | `--game <id> [--logs]`                      |
/// | `faugus.runner <command>`               | `--run <file> --in-game <id>`, or           |
/// |                                         | `--run <file> --in-prefix <dir> [--runner]` |
/// | `faugus.runner --splash/--donate/...`   | same flags                                  |
/// | `faugus.backup_daemon --daemon`         | `--daemon [--once]`                         |
/// | `faugus.shortcut <file>`                | `--shortcut <file>`                         |
/// Where `--run <file>` runs the file.
public enum RunFileTarget: Equatable, Sendable {
    /// The prefix, runner and environment of a saved game.
    case game(id: String)
    /// A prefix from the Add Game dialog, before the game exists (installer, "Run" button).
    case prefix(path: String, runner: String, logID: String)
}

public enum LaunchMode: Equatable, Sendable {
    case launcher(hidden: Bool, console: Bool, file: String?)
    case runGame(id: String, logs: Bool, preLaunch: String, postLaunch: String)
    case runFile(path: String, target: RunFileTarget, logs: Bool, preLaunch: String, postLaunch: String)
    case splash(image: String)
    case donate
    case dialog(message: String, detail: String)
    case winetricksLog
    case daemon(once: Bool)
    case createShortcut(file: String)
    case invalid(String)

    /// `arguments` excludes the executable name (`CommandLine.arguments.dropFirst()`).
    public static func parse(_ arguments: [String]) -> LaunchMode {
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []

        let valueOptions: Set<String> = [
            "--game", "--run", "--in-game", "--in-prefix", "--runner", "--log-id", "--pre-launch", "--post-launch", "--splash", "--dialog",
            "--dialog-detail", "--shortcut",
        ]
        let flagOptions: Set<String> = [
            "--logs", "--donate", "--winetricks-log", "--daemon", "--once", "--hide", "--console",
            "--ui-child",
        ]

        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if isSystemInjected(a) {
                // `-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState YES`, ...
                i += a.hasPrefix("-psn_") ? 1 : 2
                continue
            }
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--"), valueOptions.contains(String(a[..<eq])) {
                options[String(a[..<eq])] = String(a[a.index(after: eq)...])
            } else if valueOptions.contains(a) {
                guard i + 1 < arguments.count else { return .invalid("\(a) requires a value") }
                options[a] = arguments[i + 1]
                i += 1
            } else if flagOptions.contains(a) {
                flags.insert(a)
            } else if a.hasPrefix("--") {
                return .invalid("unrecognized argument \(a)")
            } else {
                positionals.append(a)
            }
            i += 1
        }

        let pre = options["--pre-launch"] ?? ""
        let post = options["--post-launch"] ?? ""
        let logs = flags.contains("--logs")

        // Same precedence as upstream's runner `main()`.
        if let image = options["--splash"] { return .splash(image: image) }
        if flags.contains("--donate") { return .donate }
        if let message = options["--dialog"] {
            return .dialog(message: message, detail: options["--dialog-detail"] ?? "")
        }
        if flags.contains("--winetricks-log") { return .winetricksLog }
        if flags.contains("--daemon") { return .daemon(once: flags.contains("--once")) }
        if let file = options["--shortcut"] { return .createShortcut(file: file) }
        if let id = options["--game"] {
            return .runGame(id: id, logs: logs, preLaunch: pre, postLaunch: post)
        }
        if let path = options["--run"] {
            if let game = options["--in-game"], !game.isEmpty {
                return .runFile(path: path, target: .game(id: game), logs: logs, preLaunch: pre, postLaunch: post)
            }
            if let prefix = options["--in-prefix"], !prefix.isEmpty {
                let target = RunFileTarget.prefix(
                    path: prefix, runner: options["--runner"] ?? "", logID: options["--log-id"] ?? "")
                return .runFile(path: path, target: target, logs: logs, preLaunch: pre, postLaunch: post)
            }
            return .invalid("--run requires --in-game <id> or --in-prefix <dir>")
        }

        // Launcher: `main()` removes --hide/--console/--ui-child, then exactly one positional
        // argument means "run this file".
        if positionals.count > 1 { return .invalid("unexpected extra arguments") }
        return .launcher(
            hidden: flags.contains("--hide"), console: flags.contains("--console"),
            file: positionals.first)
    }

    private static func isSystemInjected(_ a: String) -> Bool {
        a.hasPrefix("-NS") || a.hasPrefix("-Apple") || a.hasPrefix("-psn_")
            || a == "-AppleLanguages" || a == "-AppleLocale"
    }

    /// Modes that start a GUI event loop as a regular (Dock) app.
    public var isInteractiveLauncher: Bool {
        if case .launcher = self { return true }
        return false
    }
}
