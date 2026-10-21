# Engine notes: attention and file watching

## When the engine raises attention

`AgentEngineUpdate.attention` comes only from transitions observed as they happen:

- **Never from history.** Nothing is raised while `start()` runs, from the peek or the
  background history load, from the first read of any file (`AgentSignal.isReplay`), or for
  evidence older than 60 s.
- **One "finished" per turn.** A turn starts when a session goes from not-busy to working; a
  second "finished" needs a new turn, so the same moment reported by a hook, the transcript,
  the status file and OSC yields one event. Repeats of "needs input" / "failed" within 30 s
  (without a new turn) are dropped. Held permission requests are always raised (each is
  actionable).
- **Content is plain text, built once** (`AttentionText`): the title is the session's title
  (the one Fleet shows); bodies are markdown-stripped, collapsed, home paths shortened to `~`,
  ≤ 140 chars at a word boundary; permission bodies are `Tool: command` (no markdown handling).
  `event.date` is the time of the evidence, not of emission.
- `event.surface` is the session's pane, preserved through provisional→real key merges, and
  nil for external sessions.

## File watching

FSEvents can't register a client on this machine (macOS 27, ad-hoc signed processes:
`FSEventStreamStart` returns false for CLI, launchd jobs and LaunchServices-launched apps).
The engine therefore watches with kqueue (`EVFILT_VNODE`: write/extend/delete/rename):

- live sessions' transcript files and their directories (new files after `/clear`),
  per-session state files (Claude's `sessions/<pid>.json`), Claude's sessions directory,
  Codex's `session_index.jsonl` and today's `sessions/YYYY/MM/DD`, OpenCode's DB, WAL and dir;
- a directory event lists only files modified since the last listing; a deleted or renamed
  file is unwatched and re-watched when it reappears (rotation);
- a stat poll remains as a safety net: every 5 s while kqueue is healthy, 1 s otherwise.

Measured with `mship-probe --latency 40` (transcript write → `updates()` emission): kqueue
median 0.7 ms, p95 5 ms, max 84 ms (the ≤ 10/s update coalescing); 1 s polling median 843 ms.
