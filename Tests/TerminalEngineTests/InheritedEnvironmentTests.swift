import Testing
@testable import TerminalEngine

@Test func hostSessionMarkersAreScrubbedButUserConfigIsKept() {
    for name in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "VSCODE_IPC_HOOK_CLI", "TERM_PROGRAM", "TMUX", "CODEX_SANDBOX"] {
        #expect(InheritedEnvironment.shouldScrub(name), "\(name)")
    }
    for name in ["PATH", "HOME", "ANTHROPIC_API_KEY", "MOTHERSHIP_HOME", "LANG", "SHELL", "EDITOR"] {
        #expect(!InheritedEnvironment.shouldScrub(name), "\(name)")
    }
}
