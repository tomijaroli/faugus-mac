import Foundation

/// Rosetta 2 is required because Gcenx Wine builds are x86_64 (plan section 4).
public enum Rosetta {
    public static let archPath = "/usr/bin/arch"

    /// `/usr/bin/arch -x86_64 /usr/bin/true` succeeds only when Rosetta is installed.
    public static func isInstalled() async -> Bool {
        guard let r = try? await ProcessRunner.run(archPath, ["-x86_64", "/usr/bin/true"]) else { return false }
        return r.succeeded
    }

    /// The shell command run (with an administrator prompt) to install Rosetta.
    public static let installShellCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"

    /// AppleScript that runs `installShellCommand` after the standard macOS admin prompt.
    public static var installAppleScript: String {
        "do shell script \"\(installShellCommand)\" with administrator privileges"
    }

    public enum InstallError: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// Installs Rosetta via an admin prompt (`osascript`). Throws `.cancelled` when the user
    /// dismisses the prompt.
    public static func install() async throws {
        let r = try await ProcessRunner.run("/usr/bin/osascript", ["-e", installAppleScript])
        if r.succeeded {
            return
        }
        if r.stderr.contains("-128") || r.stderr.lowercased().contains("user canceled") {
            throw InstallError.cancelled
        }
        throw InstallError.failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
