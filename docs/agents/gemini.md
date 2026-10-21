# Gemini CLI (installed 0.18.4 — no working hooks)

Sources: installed package `@google/gemini-cli-core` 0.18.4 (`dist/src/hooks/types.d.ts`,
`hookRunner.js`, `config/settingsSchema.js`), [Google Developers Blog: hooks](https://developers.googleblog.com/tailor-gemini-cli-to-your-workflow-with-hooks/),
[hooks comparison](https://lilting.ch/en/articles/gemini-cli-hooks-research), `gemini --help`.

## Hooks

0.18.4 ships the hook registry/planner/runner and a `tools.enableHooks` setting (default false,
"requires MessageBus integration"), but **nothing fires hook events** (no call sites). Hooks
shipped in **v0.26.0**. So:

- `installIntegration(.gemini)` throws `unsupported("Gemini CLI 0.18.4 has no hooks (needs ≥ 0.26.0)")`
  and `integrationStatuses()` says so. On ≥ 0.26 it merges into `~/.gemini/settings.json`
  (same `hooks.<Event>[{matcher?, hooks:[{type:"command", command, timeout}]}]` shape;
  **timeout in milliseconds**, default 60 000).
- Events (from the 0.18 types; same names in 0.26): SessionStart(`source`), SessionEnd(`reason`),
  BeforeAgent(`prompt`) → working, AfterAgent(`prompt_response`) → idle, BeforeTool/AfterTool
  (`tool_name`, `tool_input`), Notification(`notification_type: ToolPermission`, `message`) →
  needsInput(.permission) (non-blocking: Gemini has no allow/deny hook output), PreCompress.
  Common input: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`.
- No permission hold for Gemini (no decision channel); the prompt stays in its TUI.

## Process & history

`node ~/.npm-global/bin/gemini` relaunches itself as a child node process (bigger heap); the
parent is the root. Chats: `~/.gemini/tmp/<sha256(cwd)>/chats/session-<ts>-<id8>.json`, one JSON
document rewritten on each update: `{sessionId, projectHash, startTime, lastUpdated, messages:
[{type: user|gemini|info|error, content, model?, tokens?{input, output, cached, thoughts, tool, total}}]}`.
Re-read whole on change (small); totals recomputed (`cached` is a subset of `input`).

## Commands

Resume `gemini --resume <id>` (0.18.4 accepts only `latest` or an index; newer versions take ids);
launch `gemini -i "<prompt>"` (`-i` keeps it interactive; a positional prompt is one-shot).
