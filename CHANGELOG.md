# Changelog

This project follows [Semantic Versioning](https://semver.org). Until 1.0, minor versions may
break things.

## [Unreleased]

The first public preview.

### Terminal and workspaces
- libghostty terminal with vertical-tab workspaces, splits and a ⌘K palette.
- Persistent sessions: `mshipd` keeps shells and agents alive across quits and crashes, and
  panes reattach with their screen and scrollback.

### Agent engine
- Claude Code, Codex, OpenCode and Gemini CLI, plus nine manifest agents, including sessions
  outside Mothership.
- Live state, summaries, titles, tokens, cost and context, without hooks.
- Hooks and plugin with consent and backups.
- Approve or deny permission requests from the sidebar, notifications, Fleet or
  `mship approve`/`deny`.

### Tasks
- New Task and Best-of-N in git worktrees, with Compare, a diff viewer, Keep (as a PR, a
  merge or a branch) and Discard.
- GitHub PR status chips.

### Browser and tools
- Browser pane with DOM snapshots, click/fill/eval, console capture, screenshots and an
  element picker.
- `mship` CLI and MCP server.

### Look and feel
- Themes: Mothership Sky follows the real sun; 18 more built-in themes; user themes in JSON.
  The Motion setting (Full, Subtle, Off) has battery and Low Power policies.
- Home, Fleet, toasts, actionable notifications and the Arch M icon.

### Release
- Hardened-runtime release pipeline with DMG packaging. Notarization needs a Developer ID.
