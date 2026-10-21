import Darwin
import Foundation

// Pure helpers the app uses to start panes. They live here (rather than in the app target,
// which has no test target) so ControlPlaneTests can exercise them against real shells.

/// Starting a pane with a command (an agent, a dev server) without typing it into a shell.
///
/// Typing into a shell that is still loading its rc files is a race: with an "instant
/// prompt" (powerlevel10k and friends) the prompt is already drawn and bracketed paste is on,
/// so pasted text is echoed by the tty, `^[[200~…^[[201~` markers and all, before zsh runs it.
/// Instead the pane's process is the user's own login shell running the command, which then
/// replaces itself with an interactive login shell:
///
///     zsh -l -i -c '<fixed script>'      MOTHERSHIP_STARTUP_COMMAND='claude "fix the tests"'
///
/// The command travels in the environment, so it needs no quoting and a syntax error in it
/// can't break the wrapper. The wrapper catches SIGINT (`trap : INT`), so Ctrl-C stops the
/// command and leaves a working shell; the command itself runs as a normal foreground job,
/// leading the terminal's foreground process group (which agent and quit detection rely on).
/// One difference from typing it: after Ctrl-C, the rest of a `;`-separated list still runs
/// (`&&` chains stop as usual). Before exec'ing the interactive shell the script re-arms
/// Ghostty's shell integration (zsh's integration restores `ZDOTDIR` early in startup; bash
/// 4+'s needs `--posix` + `ENV`), so cwd/title tracking and prompt marks keep working.
public enum ShellLaunch {
    /// Carries the command line into the wrapper; unset before the command runs.
    public static let commandVariable = "MOTHERSHIP_STARTUP_COMMAND"

    public enum Family: Equatable, Sendable {
        case zsh, bash, posix, fish
        /// nu, xonsh, elvish…: no `-c` contract we can rely on.
        case unsupported
    }

    public static func family(of shell: String) -> Family {
        var name = (shell as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        switch name {
        case "zsh": return .zsh
        case "bash": return .bash
        case "sh", "dash", "ksh", "mksh", "oksh", "yash": return .posix
        case "fish": return .fish
        default: return .unsupported
        }
    }

    /// The user's login shell: the account database first (what Terminal and Ghostty use),
    /// then `$SHELL`, then zsh.
    public static func userShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// The pane process for "run `$commandVariable`, then be an interactive shell", as one
    /// shell command line (Ghostty runs it through `/bin/sh -c`). Nil for shells without a
    /// usable `-c`; callers then type the command once the shell is ready instead.
    public static func command(shell: String) -> String? {
        let script: String
        switch family(of: shell) {
        case .zsh: script = zshScript(shell: shell)
        case .bash: script = bashScript(shell: shell)
        case .posix: script = posixScript(shell: shell)
        case .fish: script = fishScript(shell: shell)
        case .unsupported: return nil
        }
        return quote(shell) + " -l -i -c " + quote(script)
    }

    /// The environment entries that go with `command(shell:)`.
    public static func environment(running commandLine: String) -> [String: String] {
        [commandVariable: commandLine]
    }

    /// POSIX single-quoting: safe for any byte string in sh, bash, zsh and fish.
    public static func quote(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")

    // MARK: Scripts
    //
    // Each runs inside the user's interactive login shell, so PATH and aliases from their rc
    // files apply to the command. They must not contain single quotes (they're quoted whole).

    /// Shared by the sh-family scripts: take the command out of the environment and run it with
    /// SIGINT caught by the wrapper (the command still gets it; trapped signals reset on exec).
    private static let runCommand = """
        __mothership_cmd=${\(commandVariable)-}
        unset \(commandVariable)
        trap : INT
        eval "$__mothership_cmd"
        trap - INT
        unset __mothership_cmd
        """

    private static func zshScript(shell: String) -> String {
        """
        \(runCommand)
        if [ -n "${GHOSTTY_ZSH_INTEGRATION_DIR-}" ]; then
          if [ -n "${ZDOTDIR+x}" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi
          export ZDOTDIR="$GHOSTTY_ZSH_INTEGRATION_DIR"
        fi
        exec -l \(doubleQuote(shell)) -i
        """
    }

    private static func bashScript(shell: String) -> String {
        """
        \(runCommand)
        __mothership_gi="${GHOSTTY_RESOURCES_DIR-}/shell-integration/bash/ghostty.bash"
        if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [ -n "${GHOSTTY_RESOURCES_DIR-}" ] && [ -r "$__mothership_gi" ]; then
          if [ -n "${ENV+x}" ]; then export GHOSTTY_BASH_ENV="$ENV"; fi
          if [ -z "${HISTFILE+x}" ]; then export HISTFILE="$HOME/.bash_history" GHOSTTY_BASH_UNEXPORT_HISTFILE=1; fi
          export GHOSTTY_BASH_INJECT=1 ENV="$__mothership_gi"
          unset __mothership_gi
          exec -l \(doubleQuote(shell)) --posix -i
        fi
        exec -l \(doubleQuote(shell)) -i
        """
    }

    private static func posixScript(shell: String) -> String {
        """
        \(runCommand)
        exec \(doubleQuote(shell)) -l -i
        """
    }

    private static func fishScript(shell: String) -> String {
        """
        set -l __mothership_cmd $\(commandVariable)
        set -e \(commandVariable)
        eval $__mothership_cmd
        exec \(doubleQuote(shell)) -l -i
        """
    }

    /// Double quotes for a path inside a script (paths with `"`, `$` or backticks are escaped).
    private static func doubleQuote(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\"$`\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"" + escaped + "\""
    }
}
