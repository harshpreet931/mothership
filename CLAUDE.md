# Mothership

AI-native macOS terminal: vertical-tab workspaces, splits, embedded browser, and an agent
engine that tracks every Claude Code / Codex / OpenCode / Gemini session on the machine.
Design: `docs/ARCHITECTURE.md`. MIT. macOS 26+, Swift 6.3, Swift 6 language mode.

## Build & test

```sh
swift build                              # everything
swift build --target AgentKit            # one module (fast)
swift test --filter AgentKitTests        # one test target (Swift Testing: `import Testing`)
scripts/bundle.sh                        # → build/Mothership.app (once it exists)
```

## Module map (arrows point down only)

| Module | Purpose |
|---|---|
| `ShipModel` | Shared contracts: IDs, `AgentSession`, `AgentState`, `HookEnvelope`, `AgentEngineProtocol`, layout snapshots, env/paths. Foundation only. |
| `ShipProtocol` | Control-socket wire format: `JSONValue`, JSON-RPC types, `ControlMethod` + params/results, `ControlHandling`. |
| `SystemProbe` | libproc/sysctl process table, argv/env, cwd, foreground pgid, ports, kqueue exits, FSEvents. |
| `AgentKit` | `AgentEngine` (implements `AgentEngineProtocol`), adapters, reducer, transcripts, installers. |
| `ControlPlane` | Unix-socket JSON-RPC server, MCP tool catalog. |
| `BrowserKit` | WKWebView browser surface + automation. |
| `AttentionKit` | Notifications with actions, Dock badge. |
| `TerminalEngine` | libghostty-spm (`GhosttyTerminal`) wrapper. |
| `MothershipApp` | The AppKit/SwiftUI app. Composition root. |
| `mship` | CLI: `mship hook`, `notify`, `open`, `split`, `status`, `mcp`. |
| `mship-probe` | Dev tool printing what the agent engine sees. |

## Rules

- **Never write to real agent configs** (`~/.claude`, `~/.codex`, `~/.config/opencode`,
  `~/.gemini`) from code under development or tests. Reading them for format discovery is
  fine; never print or copy credentials (`auth.json`, `oauth_creds.json`, `*.key`, tokens).
  Installers take a root directory parameter so tests run against temp dirs.
- Swift 6 strict concurrency. Services are actors; UI is `@MainActor`. No
  `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line comment saying why it's safe.
- No force unwraps/`try!` outside tests.
- Public API gets a short doc comment when the name doesn't say it all. Comments explain
  *why*, not *what*.
- Prefer Apple frameworks over dependencies. Ask before adding a package.
- Agent CLIs change formats often: decoders ignore unknown fields and never crash on
  unexpected input.
- The `mship hook` path must stay fast (<10 ms): no heavy imports, exit 0 silently if the
  app isn't running.
