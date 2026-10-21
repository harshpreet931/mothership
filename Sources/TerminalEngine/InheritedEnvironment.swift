import Darwin
import Foundation

/// Session markers Mothership must not pass on to its shells. Launched from another terminal or
/// agent (a VS Code terminal, a Claude Code Bash tool), the app inherits that host's identity;
/// a login shell re-reads the user's rc files, but these are never set there, so they would
/// leak into every pane: Claude Code then believes it's a child session and stops saving
/// transcripts, CLIs think they run inside VS Code or tmux, and so on.
public enum InheritedEnvironment {
    static let exactNames: Set<String> = [
        "CLAUDECODE", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
        "TMUX", "TMUX_PANE", "STY", "WINDOWID", "GIT_ASKPASS",
    ]
    static let prefixes = ["CLAUDE_CODE_", "VSCODE_", "CURSOR_TRACE_"]

    static func shouldScrub(_ name: String) -> Bool {
        exactNames.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }

    /// Removes inherited host markers from this process's environment, before any pane spawns.
    /// Returns the names removed (for logging).
    @discardableResult
    public static func scrub() -> [String] {
        let names = ProcessInfo.processInfo.environment.keys.filter(shouldScrub).sorted()
        for name in names { unsetenv(name) }
        return names
    }
}
