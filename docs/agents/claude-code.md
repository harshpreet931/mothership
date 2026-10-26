# Claude Code (validated against 2.1.306)

Sources: [Hooks reference](https://code.claude.com/docs/en/hooks) (fetched 2026-10-21), the
installed `~/.claude/settings.json` and `~/.claude/sessions/*.json`, synthetic transcripts.

## Process

- Native Mach-O at `~/.local/share/claude/versions/<x.y.z>`, symlinked from `~/.local/bin/claude`.
  `p_comm` is `claude` or the version string.
- **Multi-call binary**: Claude runs its bundled ripgrep/ugrep as the *same executable* with
  `argv[0]` = `rg` / `ugrep`; orphaned ones outlive their session (one was 6 days old on this
  machine). Only `argv[0] == "claude"` (or the version path) is a session root.
- Children: MCP servers (`node …`), plugins (`bun … ~/.claude/plugins/…`), nested `claude -p`
  from the Bash tool. All excluded by descendant exclusion. `claude mcp|config|doctor|…` are
  management commands, not sessions.
- **Per-pid status file** `~/.claude/sessions/<pid>.json` (undocumented, stable on 2.1.x):
  `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `status` (`busy` | `idle` | `waiting`
  + `waitingFor`), `name`/`nameSource` (`derived` = a `<dir>-<hex>` slug), `updatedAt`,
  `statusUpdatedAt`. AgentKit reads only these non-secret keys; the sibling `*.key` files are
  never opened. This binds a live pid to its session id without hooks, and gives Tier-2 state.
  `status: busy` persists while background agents run after the turn ended, so the newer
  transcript `end_turn` wins (newest-evidence rule).

## Hooks (`~/.claude/settings.json`)

Schema: `hooks.<Event>: [{ "matcher"?: string, "hooks": [{ "type": "command", "command", "timeout"? (seconds), "async"?, "statusMessage"? … }] }]`.
Omitted matcher = all. Default timeout 600 s (UserPromptSubmit 30 s); SessionEnd shares a 1.5 s budget.

Installed by Mothership (13 events, appended as new groups, never editing other entries):
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest
(timeout = hold + 60 s), Notification, Stop, StopFailure, SubagentStart, SubagentStop,
PreCompact, PostCompact. Command: `"<ShipPaths.cliShim>" hook claude <Event>`.

Common input: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`
(+ `prompt_id`, `agent_id`/`agent_type` in subagents). Per event:

| Event | Fields used | Signal |
|---|---|---|
| SessionStart | `source` (startup/resume/clear/compact/fork), `model`, `session_title` | sessionStarted (+metadata) |
| SessionEnd | `reason` (clear/resume/logout/prompt_input_exit/other) | sessionEnded |
| UserPromptSubmit | `prompt`, `session_title` | promptSubmitted |
| PreToolUse | `tool_name`, `tool_input`, `tool_use_id` | toolStarted(tool, summary) |
| PostToolUse(Failure) | `tool_name`, `tool_response` | toolFinished |
| PermissionRequest | `tool_name`, `tool_input`, `permission_suggestions` (no tool_use_id) | permissionRequested (held, §6) |
| Notification | `message`, `title`, `notification_type` | permission_prompt → needsInput(.permission); elicitation_* / agent_needs_input → needsInput(.question); idle_prompt, auth_success … → nothing |
| Stop | `last_assistant_message`, `stop_hook_active` | turnCompleted |
| StopFailure | `error` (rate_limit, overloaded, …), `error_details` | failed |
| Subagent{Start,Stop} | `agent_id`, `agent_type` | subagent count ± 1 |
| Pre/PostCompact | `trigger` (manual/auto) | working("Compacting") / back to working or idle |

`idle_prompt` deliberately does **not** flip an idle session to needsInput (it fires ~60 s after
every turn; the Stop already produced "finished"). Deviation from the §5.2 diagram, on purpose.

### PermissionRequest decision (stdout, exit 0)

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"<reason>"}}}
```

Exit 0 with no output = no decision → Claude shows its own prompt (passthrough). Exit 2 is not
honoured for PermissionRequest. We never send `updatedInput`, `updatedPermissions` or `interrupt`.

## Transcripts

`~/.claude/projects/<cwd with every non-alphanumeric char → "-">/<session>.jsonl`, appended
compactly (`"type":"assistant"` — the line prefilter relies on that). Records used:
`user` (string or content array; `tool_result` items = tool finished; `<command-…>` echoes
ignored), `assistant` (`message.id`, `model`, `usage`, `content[].tool_use|text`,
`stop_reason`), `system/turn_duration` (turn ended), `ai-title`, `custom-title`, `last-prompt`,
`summary`. **One assistant message is written as several lines (one per content block) sharing
`message.id` and usage**: usage is de-duplicated by id (delta against the previous line) and
emitted as the file's running total, so re-reading a file never double-counts.
Context fill = latest `input + cache_read + cache_creation`. Subagent transcripts live under
`<session>/subagents/` and are not separate sessions. Big transcripts (150 MB seen) are read
from the last 32 MB on first sight, so token totals for very long sessions are partial.

## Titles and summaries

Normal CLI sessions carry **no title record** (on a development machine, 116 of 120 CLI transcripts had
none); `ai-title` / `custom-title` appear in Claude Desktop sessions and some agent sessions, and
the status file `name` is a slug unless renamed. Precedence: user rename (`custom-title`,
non-derived status `name`) > `ai-title`/`summary` (newest wins) > the earliest prompt with the
user's own words (pasted `<pasted_content>` blocks only as a fallback), cleaned by
`TitleCleaner` (markdown, quotes, `@file` refs, paths, URLs, placeholders; ≤ 48 chars at a word
boundary) > the folder name. Huge transcripts are read as head (1 MB) + byte-scan of the skipped
middle for title records and plain-text prompts (`"message":{"role":"user","content":"`) +
the newest 32 MB, after a 256 KB peek that sets the current state within ~50 ms of `start()`.
Summaries: the current tool phrased ("Running pnpm test", "Editing AppModel.swift") while
working; the first sentence (≤ 80 chars, markdown stripped) of the last reply when idle.

## Commands

Resume `claude --resume <id>`; launch `claude "<prompt>"` (positional prompt starts interactive).
