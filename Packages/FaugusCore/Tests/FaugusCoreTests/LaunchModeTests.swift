@testable import FaugusCore
import Testing

@Suite("CLI verbs")
struct LaunchModeTests {
    @Test func launcherDefaults() {
        #expect(LaunchMode.parse([]) == .launcher(hidden: false, console: false, file: nil))
        #expect(LaunchMode.parse(["--hide"]) == .launcher(hidden: true, console: false, file: nil))
        #expect(LaunchMode.parse(["--console", "--hide"]) == .launcher(hidden: true, console: true, file: nil))
        #expect(LaunchMode.parse(["--ui-child"]) == .launcher(hidden: false, console: false, file: nil))
    }

    @Test func singleFileArgument() {
        #expect(LaunchMode.parse(["/tmp/setup.exe"]) == .launcher(
            hidden: false,
            console: false,
            file: "/tmp/setup.exe"
        ))
        #expect(LaunchMode.parse(["--hide", "/tmp/a.msi"]) == .launcher(
            hidden: true,
            console: false,
            file: "/tmp/a.msi"
        ))
        if case .invalid = LaunchMode.parse(["a.exe", "b.exe"]) {} else {
            Issue.record("expected invalid")
        }
    }

    @Test func runGame() {
        #expect(
            LaunchMode.parse(["--game", "celeste"])
                == .runGame(id: "celeste", logs: false, preLaunch: "", postLaunch: "")
        )
        #expect(
            LaunchMode.parse(["--game=celeste", "--logs", "--pre-launch", "a.sh", "--post-launch=b.sh"])
                == .runGame(id: "celeste", logs: true, preLaunch: "a.sh", postLaunch: "b.sh")
        )
    }

    @Test func runFile() {
        #expect(
            LaunchMode.parse(["--run", "/tmp/x.exe", "--in-game", "celeste", "--logs"])
                == .runFile(
                    path: "/tmp/x.exe",
                    target: .game(id: "celeste"),
                    logs: true,
                    preLaunch: "",
                    postLaunch: ""
                )
        )
        #expect(
            LaunchMode.parse(["--run", "/tmp/x.exe", "--in-prefix", "/tmp/p", "--runner", "GE", "--log-id", "my-game"])
                == .runFile(
                    path: "/tmp/x.exe", target: .prefix(path: "/tmp/p", runner: "GE", logID: "my-game"),
                    logs: false, preLaunch: "", postLaunch: ""
                )
        )
        #expect(
            LaunchMode.parse(["--run", "/tmp/x.exe"])
                == .invalid("--run requires --in-game <id> or --in-prefix <dir>")
        )
    }

    @Test func helperWindows() {
        #expect(LaunchMode.parse(["--splash", "/tmp/i.png"]) == .splash(image: "/tmp/i.png"))
        #expect(LaunchMode.parse(["--donate"]) == .donate)
        #expect(LaunchMode.parse(["--dialog", "Oops", "--dialog-detail", "More"]) == .dialog(
            message: "Oops",
            detail: "More"
        ))
        #expect(LaunchMode.parse(["--dialog", "Oops"]) == .dialog(message: "Oops", detail: ""))
        #expect(LaunchMode.parse(["--winetricks-log"]) == .winetricksLog)
    }

    @Test func daemonAndShortcut() {
        #expect(LaunchMode.parse(["--daemon"]) == .daemon(once: false))
        #expect(LaunchMode.parse(["--daemon", "--once"]) == .daemon(once: true))
        #expect(LaunchMode.parse(["--shortcut", "/tmp/a.exe"]) == .createShortcut(file: "/tmp/a.exe"))
    }

    @Test func precedenceMatchesUpstreamRunner() {
        // splash > donate > dialog > winetricks-log > game
        #expect(LaunchMode.parse(["--game", "x", "--splash", "i.png"]) == .splash(image: "i.png"))
        #expect(LaunchMode.parse(["--game", "x", "--donate"]) == .donate)
        #expect(LaunchMode.parse(["--game", "x", "--winetricks-log"]) == .winetricksLog)
    }

    @Test func ignoresSystemInjectedArguments() {
        #expect(
            LaunchMode.parse([
                "-NSDocumentRevisionsDebugMode",
                "YES",
                "-ApplePersistenceIgnoreState",
                "YES",
                "--game",
                "a",
            ])
                == .runGame(id: "a", logs: false, preLaunch: "", postLaunch: "")
        )
        #expect(LaunchMode.parse(["-psn_0_12345"]) == .launcher(hidden: false, console: false, file: nil))
    }

    @Test func errors() {
        if case .invalid = LaunchMode.parse(["--game"]) {} else {
            Issue.record("missing value")
        }
        if case .invalid = LaunchMode.parse(["--bogus"]) {} else {
            Issue.record("unknown flag")
        }
    }
}
