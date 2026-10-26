# Codex CLI (validated against 0.146.0)

Sources: [Codex hooks](https://developers.openai.com/codex/hooks) (`hooks.md`, fetched 2026-10-21),
[generated schemas](https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated),
event names confirmed with `strings` on the installed native binary, `codex --help`,
`codex resume --help`, the installed `~/.codex/hooks.json` / `config.toml` (keys only).

## Process

npm wrapper `~/.npm-global/bin/codex` (node script) → spawns the native binary
`…/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`. The wrapper is the root;
the native child is excluded. `codex app-server` (Codex Desktop), `mcp-server`, `exec-server`,
`login`, `doctor`, … are not sessions; `codex exec` is.

Session binding without hooks: the native process keeps its rollout file open, so
`PROC_PIDLISTFDS` → `rollout-…-<uuid>.jsonl` gives the session id (fallback `codex resume <id>` in argv).

## Hooks (`~/.codex/hooks.json`)

Same shape as Claude: `{"description"?: …, "hooks": {"<Event>": [{"matcher"?, "hooks": [{"type":"command","command","timeout"? (s),"statusMessage"?,"async"?}]}]}}`.
Default timeout 600 s; SessionEnd/Interrupt 1–3 s. Commands run via `$SHELL -lc` in the session cwd.
Hooks from multiple sources all run, **concurrently**.

Events in 0.146 (binary): SessionStart, SessionEnd, UserPromptSubmit, PreToolUse,
PermissionRequest, PostToolUse, Stop, SubagentStart, SubagentStop, PreCompact, PostCompact.
(`Interrupt` is documented but not in 0.146; not installed, decoded if it ever arrives.)
Mothership installs those 11; PermissionRequest timeout = hold + 60 s.

**Trust.** Non-managed hooks are skipped until reviewed in `/hooks`; trust is recorded in
`config.toml` as `[hooks.state."<hooks.json path>:<snake_event>:<group index>:<hook index>"] trusted_hash = …`.
Consequences: (1) Mothership appends its groups at the end of each event's list so existing
groups keep their indices (and their trust); (2) after install the user must approve in `/hooks`;
`integrationStatuses()` reports "trust pending" by looking for those keys; (3) `[features] hooks = false`
is reported. `notify` in `config.toml` (often already used by another program) is never touched.

Common input: `session_id` (subagent hooks carry the parent id), `transcript_path`, `cwd`,
`hook_event_name`, `model`, `turn_id`, `permission_mode`. PermissionRequest:
`tool_name` (`Bash`, `apply_patch`, `mcp__server__tool`), `tool_input` (`command`; `description`
when Codex has one). Stop: `last_assistant_message`, `stop_hook_active`.

### PermissionRequest decision

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"<reason>"}}}
```

No decision (exit 0, empty stdout) → normal approval prompt. Any `deny` from any hook wins.
`updatedInput`, `updatedPermissions`, `interrupt` "fail closed" today — never sent.
Stop/SubagentStop require JSON *if* stdout is non-empty; empty is fine.

## Rollouts

`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; `session_index.jsonl` has
`{id, thread_name, updated_at}`. Records used: `session_meta` (id, cwd, originator — "Codex
Desktop" becomes the host app, `source.subagent` → ignored file), `turn_context` (model, cwd),
`event_msg` `task_started` / `task_complete(last_agent_message)` / `turn_aborted` /
`user_message` / `agent_message` / `token_count` (`total_token_usage` cumulative;
`cached_input_tokens` is a subset of `input_tokens`; `last_token_usage.total_tokens` = context;
`model_context_window`), `response_item` `function_call|custom_tool_call` (`exec_command` → Bash,
`apply_patch` → "Edit <file>") and their `_output`s. Older `exec_approval_request` events map to
needsInput(.permission).

Titles: `session_index.jsonl` is read at start and tailed; each `{id, thread_name}` line is an
attach-only fact (it never creates a session; it's applied when that thread shows up).

## Commands

Resume `codex resume <id>`; launch `codex "<prompt>"`.
