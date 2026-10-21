import Darwin
import Foundation
import GhosttyKit
import GhosttyTerminal
import SessionHost
import ShipModel

/// How a pane's process starts when `mshipd` owns its PTY.
///
/// With the `.exec` backend Ghostty spawns the shell itself and adds its environment
/// (`TERM=xterm-ghostty`, `TERMINFO`, `GHOSTTY_RESOURCES_DIR`, …) and shell integration
/// (zsh via `ZDOTDIR`, bash via `--posix` + `ENV`). A daemon-spawned shell gets exactly the same
/// here, so OSC 7 cwd, OSC 133 marks, titles, readiness and the `ShellLaunch` startup wrapper
/// behave identically.
public enum PersistentShell {
    /// What Ghostty exports for this app's config (`shell-integration-features` default).
    static let shellFeatures = "cursor:blink,path,sudo,title"

    /// The spawn spec for a pane.
    /// - Parameters:
    ///   - command: A shell command line to run instead of the login shell (Ghostty runs
    ///     `command` through `/bin/sh -c` too), e.g. a `ShellLaunch` wrapper.
    ///   - environment: The pane's extra variables (MOTHERSHIP_*, the `mship` shim PATH…),
    ///     applied over this process's environment.
    public static func spec(
        command: String?, workingDirectory: String?, environment: [String: String],
        shell: String = defaultShell(), base: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpawnSpec {
        var env = base.filter { !InheritedEnvironment.shouldScrub($0.key) }
        env.merge(environment) { _, pane in pane }
        env.merge(ghosttyEnvironment(base: env)) { _, ghostty in ghostty }

        let name = (shell as NSString).lastPathComponent
        var executable = shell
        var arguments = ["-" + name]  // a login shell, as terminals start it
        if let resources = GhosttyRuntimeResources.directoryURL?.path {
            switch name {
            case "zsh":
                // Ghostty's bootstrap .zshenv restores the user's ZDOTDIR, then loads the integration.
                if let user = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = user }
                env["ZDOTDIR"] = resources + "/shell-integration/zsh"
            case "bash" where shell != "/bin/bash":
                // macOS's /bin/bash is 3.2, which Ghostty's integration (and ENV in posix login
                // mode) doesn't support; newer bashes get the same injection Ghostty does.
                if let user = env["ENV"] { env["GHOSTTY_BASH_ENV"] = user }
                if env["HISTFILE"] == nil {
                    env["HISTFILE"] = (env["HOME"] ?? NSHomeDirectory()) + "/.bash_history"
                    env["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
                }
                env["GHOSTTY_BASH_INJECT"] = "1"
                env["ENV"] = resources + "/shell-integration/bash/ghostty.bash"
                arguments.append("--posix")
            default:
                break
            }
        }
        if let command {
            executable = "/bin/sh"
            arguments = ["/bin/sh", "-c", command]
        }
        return SpawnSpec(
            executable: executable, arguments: arguments, environment: env,
            workingDirectory: existingDirectory(workingDirectory) ?? env["HOME"] ?? NSHomeDirectory()
        )
    }

    /// The terminal identity Ghostty gives its children.
    static func ghosttyEnvironment(base: [String: String]) -> [String: String] {
        var env = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": ghosttyVersion,
            "GHOSTTY_SHELL_FEATURES": shellFeatures,
        ]
        if let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL?.path { env["TERMINFO"] = terminfo }
        if let resources = GhosttyRuntimeResources.directoryURL?.path {
            env["GHOSTTY_RESOURCES_DIR"] = resources
            let share = (resources as NSString).deletingLastPathComponent
            env["MANPATH"] = (base["MANPATH"].map { $0 + ":" } ?? ":") + share + "/man"
            env["XDG_DATA_DIRS"] = (base["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share") + ":" + share
        }
        if let binary = Bundle.main.executableURL?.deletingLastPathComponent().path { env["GHOSTTY_BIN_DIR"] = binary }
        return env
    }

    static let ghosttyVersion: String = {
        let info = ghostty_info()
        guard let pointer = info.version else { return "1.3" }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len))
        return String(decoding: bytes, as: UTF8.self)
    }()

    /// The account's login shell (what Ghostty and Terminal start).
    public static func defaultShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : nil
    }
}
