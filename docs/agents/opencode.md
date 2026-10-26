# OpenCode (validated against 2.1.2)

Sources: [Plugins](https://opencode.ai/docs/plugins/) (fetched 2026-10-21), the plugin/SDK type
definitions shipped in `~/.config/opencode/node_modules/@opencode-ai/{plugin,sdk}` (1.4.7, incl.
`sdk/dist/v2/gen/types.gen.d.ts`), `opencode --help`, the read-only schema of
`~/.local/share/opencode/opencode.db`. A third-party plugin on a development machine showed the runtime
shape; nothing was copied from it.

## Process model (v2)

`opencode` (native binary, `~/.opencode/bin/opencode`) is a TUI that talks to a **background
service** `opencode serve --service` (launchd child, no tty). The agent loop *and plugins run in
the service*, not in the TUI. Consequences:

- The TUI process is the session root; `serve`/`service`/`acp`/`web`/`mcp`/`auth`/… are not.
- Plugin events carry no `MOTHERSHIP_SURFACE_ID` in service mode (service env), and the hook's
  parent pid is the service. The engine attributes them by session id, and binds the TUI pid to a
  session via `--session <id>` in argv or the newest `session_v2` row for the TUI's cwd.
- `--standalone` runs a private server inside the TUI; then env/pid work like other agents.

## Plugin (`~/.config/opencode/plugins/mothership.js`)

API: `export const X = async ({ client, project, directory, worktree, serverUrl, $ }) => ({ event: async ({ event }) => … })`.
Events forwarded (filtered, trimmed, serialized through one promise chain to keep order):
`session.created|updated|deleted|status|idle|error|compacted`, `message.updated` (assistant,
completed only), `message.part.updated` (tool parts, only on status change), a synthetic
`message.user` (first text part of a user message), `permission.asked|replied`,
`question.asked|replied|rejected`. Text deltas are never forwarded.

Each event spawns `"<shim>" hook opencode <type>` with `{type, properties, directory, pid}` on stdin.
For `permission.asked` the plugin waits (≤ hold + 30 s) for the shim's stdout:
`{"decision":"allow"|"deny","message"?}` → replies through the SDK
(`client.permission.reply({requestID, reply: "once"|"reject", message})`, falling back to the v1
`postSessionIdPermissionsPermissionId` and finally `POST /permission/{id}/reply` on `serverUrl`).
Empty stdout = no decision. Because OpenCode already shows its own prompt concurrently, a reply in
the TUI emits `permission.replied`, which releases Mothership's hold (matched by request id).

`permission.ask` exists in the 1.x plugin types but isn't reliably invoked by 2.x; we don't rely on it.

## Database (chosen over the `serve` event stream)

`opencode.db` (SQLite WAL), opened `file:…?mode=ro` with `SQLITE_OPEN_READONLY|SQLITE_OPEN_URI`,
200 ms busy timeout, re-queried when `opencode.db`/`-wal` changes. v2 tables: `session_v2`
(`id, directory, title, parent_id, model` JSON `{id, providerID}`, `tokens_*`, `cost`,
`time_updated`, `time_idle`, `idle_outcome`, `time_archived`) and `session_message`
(`type` user|assistant|idle|compaction|…, JSON `data`; assistant has `time.completed`, `finish`,
`error`, `content[]`). Falls back to 1.x `session`/`message`. Unknown schema → no data, no crash.

Why SQLite rather than `opencode serve`'s SSE stream: it works for TUI, standalone and desktop
sessions alike, needs no server auth (the service may require a password), survives server
restarts, and gives reported cost/tokens directly. The plugin covers real-time state; the DB covers
history, usage, external sessions and the no-plugin case.

## Commands

Resume `opencode --session <id>`; launch `opencode --prompt "<prompt>"`.
