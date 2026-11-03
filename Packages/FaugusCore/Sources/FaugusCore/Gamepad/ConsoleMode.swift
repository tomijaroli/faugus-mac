import Foundation

/// `--console` runtime overrides: Carrousel, gamepad on, fullscreen. Nothing is written to
/// `config.json` (`FaugusApp.__init__` when `console_mode`).
public enum ConsoleMode {
    public static func interfaceMode(isConsole: Bool, stored: InterfaceMode) -> InterfaceMode {
        isConsole ? .carrousel : stored
    }

    public static func gamepadEnabled(isConsole: Bool, stored: Bool) -> Bool {
        isConsole || stored
    }

    public static func startupWindowSize(isConsole: Bool, stored: String) -> String {
        isConsole ? "Fullscreen" : stored
    }
}
