# Mothership Architecture

An AI-native macOS terminal: vertical-tab workspaces, splits, an embedded browser, and an
agent layer that knows what every Claude Code / Codex / OpenCode / Gemini / … session on the
machine is doing, and can tell you when one needs you.

Status: in progress since 2026-10-21. MIT licensed, macOS 26+, CLI `mship`. Items marked **[SPIKE]** are
assumptions to confirm in code before the design depends on them.

---

## 1. Positioning: what already exists and where the edge is

- **Ghostty** is the fastest, most correct terminal on macOS. Its core (`libghostty`) is
  embeddable: Ghostty's own macOS app is a Swift/AppKit shell around it.
- **cmux** (AGPL) already ships *libghostty + vertical tabs + OSC 9/99/777 notifications +
  a `notify` CLI for agent hooks + a scriptable in-app browser*. Its sidebar row shows the
  branch, PR, cwd, ports and last notification.
- **Notch/menu-bar apps** (vibe-island, notchflow, etc.) install hooks into
  `~/.claude`, `~/.codex` and `~/.config/opencode` to show agent status. Several of these have
  already edited the config files on this machine, so the configs are contested.

The baseline (vertical tabs, splits, notifications, browser) is necessary but no longer a
differentiator. **The edge has to be the agent layer:**

1. **One state engine for every agent.** It merges hooks, OSC sequences, transcripts,
   the process table and screen heuristics into a single trustworthy state per session,
   including sessions running *outside* Mothership (VS Code, iTerm, tmux).
2. **Permission prompts answered where you are.** The `PermissionRequest` hooks in both
   Claude Code and Codex can return a decision. You approve from a notification, the
   sidebar or the menu bar. No keystroke injection is needed.
3. **Restore that knows about agents.** After a quit, crash or reboot, each pane comes back
   in its cwd and the agent resumes its own session ID.
4. **One worktree per task.** "New task" creates a worktree, a workspace, an agent and a
   prompt in one step. Best-of-N runs the same prompt in parallel and compares the diffs.
5. **Agents can drive the terminal and browser.** A built-in MCP server lets an agent open
   a browser pane, snapshot the DOM, read console errors, split a pane or launch a sibling
   agent.
6. **On-device intelligence.** Apple Foundation Models produce sidebar summaries, tab
   names and "while you were away" digests. They are free, private and offline.

> If Mothership is to be closed-source or MIT, do not copy cmux code (AGPL). Ghostty and
> libghostty are MIT.

---

## 2. Core technology decisions

| Concern | Decision | Why / alternatives |
|---|---|---|
| Language | Swift 6.3, strict concurrency | Xcode 26.4 is installed. |
| Min OS | **macOS 26** | Gives Liquid Glass, the Foundation Models framework, SwiftUI `WebView`/`WebPage`, and `@Observable` everywhere. Drop to 15 only if you need users on older OSes. |
| UI | **AppKit shell + SwiftUI chrome** | Terminal and browser surfaces are `NSView`s (Metal or WebKit layers) in an AppKit split tree. The sidebar, palette, sheets, settings and fleet view are SwiftUI hosted in AppKit. Pure SwiftUI fights you on focus, first responder, key equivalents and IME. |
| Terminal engine | **libghostty**, behind a `TerminalEngine` protocol | GPU rendering, Kitty graphics, ligatures, shell integration, and Ghostty config and themes for free. Uses the MIT `libghostty-spm` package (prebuilt XCFramework): `.exec` backend with `envVars`/`workingDirectory`/`command`, delegates for title, pwd, bell, OSC notifications, progress, command-finished, close. Its `.inMemory` backend (host-fed bytes) is the path to the v2 daemon. Move to a pinned source build with Zig once you need patches. Fallback: SwiftTerm, which is pure Swift and slower. **Never write your own VT parser.** |
| Persistence | **GRDB (SQLite)** for events, sessions and usage. **JSON** for layout snapshots | SwiftData is a poor fit for high-frequency append logs and offset tracking. |
| IPC | Unix domain socket, newline-delimited JSON-RPC 2.0 (`NWListener` with a `.unix` endpoint) | Shared by the CLI, hooks and the MCP bridge. |
| Distribution | Developer ID, notarized, Sparkle updates | The App Store sandbox is incompatible with spawning shells and reading `~/.claude` and `~/.codex`. |
| Project | One SwiftPM package (`Package.swift`) + `scripts/bundle.sh` that assembles `Mothership.app` | Builds and tests from the CLI (`swift build`, `swift test`); no `.xcodeproj` to merge. |

---

## 3. Process topology

```
┌──────────────────────────── Mothership.app ────────────────────────────────────┐
│ MainActor:  WindowController ─ Sidebar(SwiftUI) ─ PaneTree(AppKit)          │
│                                                  ├ TerminalSurface (libghostty/Metal)
│                                                  ├ BrowserSurface  (WKWebView)
│                                                  └ Diff / Markdown / Fleet surfaces
│             AppStore (@Observable) ◄── EventBus (AsyncStream, coalesced)    │
│ Actors:     ProcessProbe · AgentEngine · TranscriptIndexer · GitService ·   │
│             PortScanner · Notifier · ControlServer · MCPBridge · UsageLedger│
└───────▲──────────────────────▲─────────────────────────────▲────────────────┘
        │ JSON-RPC / unix sock │ MCP (stdio, via `mship mcp`)│ FSEvents · kqueue · libproc · sqlite(ro)
  `mship` CLI (bundled, tiny) │                               │
  ├ invoked by agent hooks ────┘                     ~/.claude/projects/**.jsonl
  ├ `mship notify|open|split|status`                ~/.codex/sessions/**, session_index.jsonl
  └ `mship mcp` (stdio↔socket bridge)               ~/.local/share/opencode/opencode.db
                                                     process table (all users' agents)
```

**v1 runs everything in-process.** libghostty surfaces own their PTYs. Design the seam now
so the PTYs can move out of the app later: the UI talks to a `TerminalSession` handle, not
to a PTY or a Ghostty surface directly.

**Persistent sessions (shipped):** `mshipd` owns every pane's PTY and a 6 MB output ring, so
shells and agents survive quitting, crashing or `kill -9` of the app. On relaunch, each pane
reattaches with its screen and scrollback through libghostty's in-memory backend. Design,
protocol and measurements: `docs/agents/sessions.md`.

---

## 4. Domain model

```swift
// Sources/ShipModel: pure value types. Codable, Sendable, no frameworks.
struct Workspace: Identifiable, Codable, Sendable {      // one vertical tab
    let id: WorkspaceID
    var name: String; var color: TabColor?; var isPinned: Bool
    var rootDirectory: URL
    var worktree: WorktreeRef?        // set when created via "New Task"
    var layout: PaneNode
    var focusedSurface: SurfaceID?
}

indirect enum PaneNode: Codable, Sendable {
    case leaf(SurfaceID)
    case split(axis: Axis, ratios: [Double], children: [PaneNode])
}

enum SurfaceKind: Codable, Sendable { case terminal, browser, diff, markdown, fleet }

struct TerminalSessionInfo: Codable, Sendable {
    let id: SurfaceID                 // exported to the shell as MOTHERSHIP_SURFACE_ID
    var shellPID: pid_t?; var cwd: URL?   // cwd from OSC 7
    var title: String                 // from OSC 0/2
    var foregroundCommand: String?    // via e_tpgid, see §5
}

struct AgentSession: Identifiable, Codable, Sendable {
    let id: AgentSessionKey           // (kind, agent's own session id)
    var kind: AgentKind               // .claude, .codex, .opencode, .gemini, .manifest("aider")
    var surface: SurfaceID?           // nil => external (VS Code, iTerm, tmux…)
    var pid: pid_t?; var cwd: URL; var repo: RepoRef?; var branch: String?
    var state: AgentState
    var pendingPermission: PermissionRequest?
    var summary: String?              // on-device model, ≤6 words
    var lastAssistantMessage: String?
    var usage: TokenUsage; var model: String?
    var startedAt: Date; var lastActivity: Date
    var unread: Bool                  // finished or needs input while not focused
}

enum AgentState: Codable, Sendable {
    case starting, idle, working(tool: String?), needsInput(InputReason),
         error(String), ended
}
```

A terminal surface hosts zero or more agent sessions over its lifetime, one at a time in
the foreground. An agent session may have no surface: it's external and observed only.

---

## 5. Agent engine (the heart)

### 5.1 Signal tiers

Each source becomes `AgentSignal { source, tier, sessionHint, payload, timestamp }`.
Higher tiers are authoritative. Lower tiers fill gaps and detect agents with no
integration.

| Tier | Source | What it gives | Notes |
|---|---|---|---|
| **0 Hooks** | Claude Code (v2.1): `SessionStart/End, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, Stop, StopFailure, SubagentStart/Stop, PreCompact, PostCompact`. Codex (0.146) `hooks.json`: `SessionStart, UserPromptSubmit, Pre/PostToolUse, PermissionRequest, Stop, Subagent*, Pre/PostCompact`. OpenCode: a JS plugin in `~/.config/opencode/plugins/` that subscribes to its event bus. Gemini: hooks if the installed version has them **[SPIKE]**. | Exact state transitions, session IDs, transcript paths, tool names, permission details | The hook command is `mship hook <agent> <event>` and payloads arrive on stdin. |
| **1 Terminal protocol** | OSC 9 / 99 / 777 notifications, BEL, OSC 0/2 title, OSC 9;4 progress, OSC 133 prompt marks, OSC 7 cwd | Universal "needs attention" and "done" signals, plus cwd and command boundaries | libghostty surfaces these as runtime *actions* (desktop notification, set title, pwd, bell, progress report). **[SPIKE]** Confirm the action names in the pinned header. Some agents animate glyphs in the title while working; this is a per-adapter heuristic. |
| **2 Transcripts / DBs** | `~/.claude/projects/<escaped-cwd>/<session>.jsonl`, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` + `session_index.jsonl`, OpenCode `~/.local/share/opencode/opencode.db` (SQLite WAL: `session`, `message`, `permission`, `session_pending`…), `~/.gemini/tmp/**` | History, token usage and cost, model, last message, and **discovery of sessions outside Mothership** | Tail-read JSONL with stored byte offsets and never re-parse a whole file. Open SQLite read-only (`mode=ro`) and watch the `-wal` file with FSEvents. OpenCode also runs `opencode serve` (HTTP plus an event stream), which may be the best source. **[SPIKE]** |
| **3 Process table** | `sysctl(KERN_PROC_ALL)` + `KERN_PROCARGS2` (argv), `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (cwd), `kqueue EVFILT_PROC/NOTE_EXIT`, `proc_pid_rusage` (CPU as a "busy" proxy) | Which agents are alive where, system-wide; exit detection | **Match the agent's root process, not its descendants.** Each `claude` here spawns MCP and plugin children (`node …`, `bun … ~/.claude/plugins/…`) whose argv contains "claude". `codex` is a node wrapper around a native binary. `claude` and `opencode` are native binaries. |
| **4 Screen heuristics** | Visible grid text, matched against per-adapter regexes (e.g. "esc to interrupt", numbered approval menus). Optional on-device classifier for unknown agents. | Fallback state for agents with no hooks | Lowest confidence. Run only on the focused or changed surface, throttled. |

**Foreground process per pane without a PTY fd.** Take the shell PID from the surface, read
`kinfo_proc.kp_eproc.e_tpgid` (the terminal's foreground process group), then find the
group leader. This gives "what's running in this pane" with one sysctl and no `lsof`.

### 5.2 State machine

```
  process seen / SessionStart
unknown ─────────────────────► idle ◄──────────── Stop ───────────────┐
                                │  UserPromptSubmit                  │
                                ▼                                    │
                             working(tool) ── PermissionRequest ──► needsInput(.permission)
                                │   ▲        Notification(idle) ──► needsInput(.question)
                                │   └──── PostToolUse / user answered ─┘
                                ├── StopFailure ─────────────► error
                                └── SessionEnd / NOTE_EXIT ──► ended   (from any state)
```

The `unread` flag is set when the state enters `idle`, `needsInput` or `error` while the
surface isn't the key, focused surface. Focusing the surface clears it.

### 5.3 Reducer: pure, deterministic, golden-tested

```swift
// Packages/AgentKit
struct AgentReducer {
    // Pure: (state, signal, now) -> state. No I/O, so it can be replayed from recorded traces.
    static func reduce(_ s: AgentSession, _ sig: AgentSignal, now: Date) -> AgentSession
}
```

Rules:
- A Tier-0 signal **locks** the state against lower tiers for a lease window (~10 s), so a
  stale screen regex can't override a fresh hook.
- `NOTE_EXIT` and `SessionEnd` always win.
- Heuristic tiers need **two agreeing samples** before changing state, to prevent
  flapping.
- Record every signal to SQLite (`signal_log`). Tests replay real traces, e.g.
  "claude: prompt → 3 tools → permission → approve → stop". **This test suite is the
  product's moat.** Agent CLIs change weekly (Claude Code is at 2.1.306), and the traces
  catch regressions.

### 5.4 Adapters

```swift
protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    func matchesRoot(_ p: ProcessSnapshot) -> Bool             // exe / argv rules
    func integration() -> IntegrationInstaller?               // hooks / plugin installer
    func decodeHook(event: String, payload: Data) -> [AgentSignal]
    func transcriptSources() -> [TranscriptSource]            // globs, sqlite, or server
    func decodeTranscript(_ record: TranscriptRecord) -> [AgentSignal]
    func screenRules() -> [ScreenRule]                        // tier 4
    func resumeCommand(session: String, cwd: URL) -> [String]?
    func launchCommand(prompt: String?, cwd: URL) -> [String]
}
```

- **Native adapters** (Swift): Claude Code, Codex, OpenCode, Gemini CLI.
- **Manifest adapters** (JSON in `~/Library/Application Support/Mothership/agents/*.json`,
  hot-reloaded) for the long tail: aider, amp, cursor-agent, copilot, goose, crush,
  qwen-code, kiro, droid. A manifest declares process matchers, title and screen regexes,
  launch and resume templates, and an optional transcript glob. The community can add
  agents without a release.

### 5.5 Installing integrations without breaking anything

This machine already has backups from four other tools that edited these files
(`settings.json.notch-relay.backup`, `hooks.json.notchflow-backup`, `vibe-island.js`, …).
Codex's single `notify` slot is already taken by Codex Computer Use. So:

- **Ask for consent per agent**, show a diff, and write a timestamped backup.
- **Merge, never replace.** Each Mothership entry is identifiable by its command
  (`…/mship hook …`), so install is idempotent and uninstall is exact.
- **Don't touch Codex `notify`.** Use `hooks.json` instead. If `notify` must be used, chain
  to the existing program.
- **Hook binary budget is under 10 ms.** `mship` is a small compiled Swift binary (no node,
  no Foundation-heavy startup), it's fire-and-forget, and it exits 0 silently if the socket
  is absent. Only `PermissionRequest` may block (§6).
- **Hooks fire from any terminal.** Inside Mothership, `MOTHERSHIP_SURFACE_ID` binds the event to
  a pane. Elsewhere, the event still reaches the app (if it's running) by `session_id` and
  `cwd`. That's what makes the fleet view cover VS Code, iTerm and tmux sessions.
- **Self-heal.** On launch, verify the hooks are still present. Other tools overwrite
  them. Surface "integration broken" in the UI instead of failing silently.

---

## 6. Answering permission prompts

The flow when Claude or Codex asks for permission:

```
agent ─PermissionRequest hook─► mship hook (blocks) ─socket─► AgentEngine
                                                               │
             pane focused & app active? ── yes ──► reply "no decision" immediately
                                                   → normal TUI prompt (zero friction)
                                     └── no ──► hold, up to a timeout:
                                                 • notification [Allow] [Deny] [Open]
                                                 • sidebar row shows inline buttons
                                                 • menu-bar extra shows inline buttons
                                               user decides → hook returns allow/deny
                                               user focuses the pane → release with
                                                 "no decision" → TUI prompt appears
                                               timeout → release with "no decision"
```

- **[SPIKE]** Confirm the exact decision JSON for each CLI. Confirm that "exit 0, no
  output" falls through to the normal prompt.
- The app never auto-approves on its own policy. The agent's own allow-lists remain the
  source of truth.
- **Fallback for agents with no permission hook:** focus the pane and highlight it. Inject
  keystrokes only behind an explicit per-agent opt-in, after re-verifying the screen shows
  the expected prompt.

---

## 7. Notifications and attention

- **`Notifier` actor**: debounces (a burst of Stop and Notification events becomes one
  alert), suppresses alerts for the focused surface, and respects Focus modes. An
  AppIntents `SetFocusFilterIntent` adds an "Mothership: only permission requests" filter.
- **Channels:** `UNUserNotificationCenter` with actionable categories (Allow, Deny,
  Open, Reply…), the sidebar ring and unread dot, a Dock badge (needs-input count), a
  `MenuBarExtra` fleet summary, a distinct sound per state, a desktop widget (WidgetKit),
  and an optional webhook or ntfy for phones. The Apple Watch gets mirrored notifications
  for free.
- **Navigation:** `⌘⇧U` jumps to the newest unread, and `⌘⌥↓` cycles through every
  needs-input session across windows.
- **"Reply" action:** for an idle agent, a text field in the notification sends a prompt
  via bracketed paste into the bound surface.

---

## 8. Session restore that knows about agents

1. Snapshot every 5 s and on quit to `layout.json`: windows, workspaces, pane tree,
   per-surface cwd, browser URLs, and **the agent session key bound to each surface**.
2. On launch, rebuild the tree and respawn the shells in their cwd. Surfaces that had an
   agent show a banner: *"Resume Claude session 'Refactor auth middleware'?"* with
   [Resume] [Resume all] [Dismiss], built from `adapter.resumeCommand` (e.g.
   `claude --resume <id>`, `codex resume <id>`, `opencode --session <id>`).
   **[SPIKE]** Verify each CLI's current flags; keep them in adapters and manifests.
3. Scrollback: persist the last N KB per surface if libghostty exposes screen and
   scrollback text **[SPIKE]**. Otherwise rely on the agent's own transcript.

---

## 9. Workspaces, worktrees, tasks

- **Vertical tab row:** name or AI summary · branch · PR state · ports · agent badges (one
  per session: spinner, orange needs-input, green done-unread, red error) · last message
  preview · cost so far. Drag to reorder, pin, color, and group by repo.
- **"New Task" (`⌘⇧N`):** choose the repo, branch name (AI-suggested from the prompt),
  agent(s) and prompt. The app runs `git worktree add <repo>.worktrees/<branch>`, then the
  repo's `.mothership/setup.sh` if present (copy `.env`, install deps, assign a port), creates
  the workspace, and launches the agent with the prompt.
- **Best-of-N:** the same prompt runs in N worktrees with different agents or models. A
  compare view shows side-by-side diffs, test results and cost, and you keep a winner.
- **Diff surface:** worktree against its base, with live updates (FSEvents) and per-hunk
  "send to agent as feedback".
- **Finish:** commit and open a PR via `gh`, then archive: remove the worktree, keep the
  transcript links and usage in history.
- **GitService** shells out to `git` and `gh`; libgit2 isn't needed. Cache status per repo
  and refresh on FSEvents in `.git/`.

---

## 10. Browser

- **`BrowserSurface`** uses the SwiftUI `WebPage`/`WebView` on macOS 26, wrapped for the
  AppKit tree, with `WKWebView` as the escape hatch. Each workspace gets its own
  `WKWebsiteDataStore(forIdentifier:)`, so localhost cookies and auth don't bleed between
  tasks. `isInspectable = true` enables the Safari Web Inspector.
- **Dev-server awareness:** `PortScanner` walks each workspace's process tree, using
  `proc_pidinfo(PROC_PIDLISTFDS)` and then `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` to find
  LISTEN sockets. Ports show in the sidebar. A URL printed in terminal output
  (`http://localhost:5173`) is ⌘-clickable into a split browser.
- **Element picker → agent.** Pick an element, and the app bracketed-pastes
  `{selector, outerHTML snippet, computed styles, screenshot path}` into the workspace's
  agent. This turns "make this button match the header" into one click.
- **Agent-drivable** through MCP tools (§11): `browser.open`, `browser.snapshot`
  (an accessibility-tree-like outline with stable element refs, via injected JS),
  `browser.click/fill/press`, `browser.eval`, `browser.console`, `browser.network_errors`,
  `browser.screenshot` (`takeSnapshot`). An agent can verify its own UI change without
  Playwright.

---

## 11. Control plane: `mship` CLI, socket, MCP

- **Socket** at `~/Library/Application Support/Mothership/control.sock`, mode `0600`. The
  server checks the peer UID (`getpeereid`) and records the peer PID (`LOCAL_PEERPID`) to
  attribute requests to a surface.
- **Environment** injected into every shell: `MOTHERSHIP_SOCKET`, `MOTHERSHIP_SURFACE_ID`,
  `MOTHERSHIP_WORKSPACE_ID`, and `PATH` with the bundled `mship` prepended. **[SPIKE]**
  Confirm that libghostty's surface config accepts env vars.
- **CLI commands:** `mship hook <agent> <event>` · `mship notify "msg"` ·
  `mship open <url> [--split right]` · `mship split [--down] -- cmd` ·
  `mship task new --repo . --agent claude "prompt"` · `mship status --json` (fleet) ·
  `mship mcp` (a stdio MCP server bridged to the socket).
- **MCP tool scope:** by default, an agent's tools are scoped to **its own workspace**,
  resolved from `MOTHERSHIP_WORKSPACE_ID`. Reading other panes' screens is opt-in, because
  terminal output is a prompt-injection and secret-exfiltration channel.
- **Shared protocol types** live in `ControlPlane/Protocol`, the only package the CLI
  links, which keeps the binary small and fast.

---

## 12. Built-in intelligence

| Feature | Model | Notes |
|---|---|---|
| Sidebar summary of what each agent is doing (≤6 words) | **On-device** (Foundation Models) | Input: last user prompt plus last assistant message. Refresh on state change only. |
| Auto-name workspaces and suggest branch names | On-device | |
| "While you were away" digest across all agents | On-device | Built from `signal_log` and transcripts. |
| Unknown-agent screen classifier (working, needs input or idle) | On-device | Tier-4 fallback with a schema-constrained (`@Generable`) output. |
| Natural language → shell command (`⌘I` in the prompt) | Cloud (Claude API, user's key) or on-device | Shows the command, never auto-runs it. |
| Explain a failed command block (OSC 133 exit ≠ 0) | Cloud or "send to agent in this workspace" | Routing to the existing agent is often better than a new model call. |
| **Prompt queue** | — | Queue prompts per agent; the next one is sent on `Stop`. |
| **Broadcast** | — | Send one prompt to several agents or worktrees. |

Don't build a chat UI that competes with the agents. Mothership hosts and orchestrates
them.

---

## 13. Usage and limits

`UsageLedger` reads token usage from transcripts (per-message usage in Claude's JSONL, token
count events in Codex rollouts, the message table in OpenCode). It stores
`(session, model, input, output, cache_read, cache_write, ts)` in SQLite and prices it from
a bundled, updatable table. The views:

- Cost per workspace, task, day and agent.
- Rolling-window usage against subscription limits, where they can be inferred.
- Context-window fill per live session, as a bar in the sidebar row.

---

## 14. Concurrency and performance

- **MainActor:** the UI and `AppStore` only. Services are actors that publish `DomainEvent`s
  into an `AsyncStream`. A MainActor consumer applies them in batches, coalescing to at
  most one sidebar update per frame (~30 Hz cap).
- **Terminal I/O and rendering** stay on libghostty's own threads. Occluded and background
  surfaces stop rendering.
- **Polling budget:** the foreground process of visible panes every 1 s (one sysctl each),
  a system-wide agent scan every 5 s, and exits are event-driven (kqueue). Transcripts and
  DBs are event-driven (FSEvents) with tail reads.

| Target | Budget |
|---|---|
| Idle CPU with 20 workspaces and 10 agents | < 0.5 % |
| Hook → sidebar update | < 100 ms |
| `mship hook` wall time | < 10 ms |
| Cold launch → usable window | < 300 ms |
| Keystroke → glyph | at libghostty parity |

---

## 15. Repository layout

```
Package.swift                      # one SwiftPM package, macOS 26, Swift 6 language mode
Sources/
├─ ShipModel/                      # shared contracts: value types + AgentEngineProtocol (§4)
├─ ShipProtocol/                   # control-socket wire format: JSON-RPC types, methods, params
├─ SystemProbe/                    # libproc, sysctl, kqueue, FSEvents, ports
├─ AgentKit/                       # adapters, manifests, reducer, installers, transcripts
├─ ControlPlane/                   # socket server, MCP tool catalog
├─ BrowserKit/                     # WKWebView surface, automation JS, element picker
├─ AttentionKit/                   # notifications, actions, Dock badge
├─ TerminalEngine/                 # libghostty-spm wrapper
├─ MothershipApp/                  # AppKit app + SwiftUI chrome (bundled by scripts/bundle.sh)
├─ mship/                          # CLI: hooks, scripting, `mship mcp`
└─ mship-probe/                    # dev tool: dump what the agent engine sees
Tests/                             # Swift Testing; AgentKitTests/Fixtures holds signal traces
scripts/bundle.sh                  # swift build → Mothership.app (+ mship inside)
```

The dependency rule is that arrows point down only:
`MothershipApp → {feature modules} → ShipProtocol → ShipModel`. `AgentKit` never imports AppKit.
The `mship` CLI links only `ShipProtocol` + `ShipModel`.

---

## 16. Roadmap

**Phase 0: spikes (1–2 weeks)**
1. Embed a libghostty surface in an AppKit window, via `libghostty-spm` and via a source
   build. Confirm the runtime actions (notification, title, pwd, bell, progress, child
   exit), env-var injection, screen-text read, and the shell PID.
2. Round trip from the `mship` binary through the socket to the app, timed against the
   10 ms budget.
3. `PermissionRequest` hold and release semantics for Claude and Codex.
4. OpenCode: compare the plugin, `opencode serve` events and polling `opencode.db`.

**Phase 1: MVP (a daily driver)**
- Windows, vertical-tab workspaces, splits, palette (`⌘K`), Ghostty config and themes.
- Socket, CLI and hook installers for Claude, Codex and OpenCode, plus Tier 1 and Tier 3
  signals.
- Agent badges, unread, notifications, jump to next.
- Layout restore.

**Phase 2: the agent workbench**
- Browser surface, port detection, ⌘-click localhost, MCP browser tools, element picker.
- New Task with worktrees, the diff surface and PRs.
- Fleet view, including external sessions. Transcript indexer and usage ledger.

**Phase 3: flagship polish**
- Remote permission approval, the menu-bar extra, the widget and Focus filter.
- Agent-aware resume, on-device summaries and digest, prompt queue and broadcast.
- Best-of-N compare, and manifest adapters for the long tail.

**Phase 4: persistence and remote**
- `mshipd` with PTY ownership, an iOS companion (fleet and approvals), and SSH remote
  agents.

---

## 17. Risks

| Risk | Mitigation |
|---|---|
| libghostty's C API is not a stable general-purpose embedding API, and upstream moved off GitHub in 2026 (unverified secondary source) | Pin a commit and keep everything behind `TerminalEngine`. Keep SwiftTerm buildable as a fallback. Budget time for each bump. |
| Agent CLIs change hooks and transcript formats constantly | Hooks first. Tolerant decoders (unknown fields ignored, unknown events logged). Trace-replay tests. Adapter version gates. Telemetry on decode failures (local only). |
| Other tools overwrite or contest hook configs | Merge-only installer, self-heal check on launch, visible "integration broken" state. |
| Keystroke injection answers the wrong prompt | Use hook decisions instead of keystrokes. Injection is opt-in and only after screen verification. |
| Prompt injection through MCP tools (an agent reads another pane or a web page) | Workspace-scoped tools by default, explicit opt-in for cross-pane reads, no secrets in the snapshot outline. |
| Scope creep: "every flagship feature" | Phase gates. Phase 1 must be a daily driver before anything in Phase 3 starts. |
