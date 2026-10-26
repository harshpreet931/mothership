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

FSEvents can't register a client on the development machine (macOS 27, ad-hoc signed processes:
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

## Idle cost

When nothing changes, the engine should do close to nothing. The app path differs from a bare
`mship-probe` run in one way: the app always has a pane open, so the engine scans the app's
process tree every second. `mship-probe --watch --app-like` reproduces that path.

- **Only real changes are published.** `SessionStore` reports whether a record changed. A scan
  that re-sees the same processes, or an unchanged status file, doesn't mark the engine dirty.
  `flush()` also diffs against the last snapshot and skips identical ones.
- **Summaries are memoized** per session by their inputs. Their regex work is bounded to the
  first ~4 KB of a reply.
- **The 1 s pane scan is a tree check.** `proc_listchildpids` and `proc_name` over the app's
  descendants cost a few syscalls. The process table is read only when the tree forked, exec'd
  or exited. Requested scans (surface open/close, command finished) and CPU-judged pane agents
  still scan.
- **Watch targets are recomputed only after a published change** or a dropped watch. Targets
  that don't exist yet are re-checked every 15 s; their parent directory's events normally
  catch them sooner.
- **The safety poll stats, never re-reads.** It uses one `stat()` per file and re-lists
  Claude's sessions dir only when its mtime moves. Status files are never evicted, because
  evicting them made every poll re-read them.
- **Hidden app.** `setAppActive(false)` (or `AttentionContext.appIsActive`) stops pane scans
  and halves the system-scan rate (8 s) and safety-poll rate (15 s). Exits stay event-driven
  (kqueue).

Measured with 10 live external Claude sessions: 60 s warm-up, then CPU time over 60 s.

| Run | Before | After |
|---|---|---|
| Engine, `mship-probe --watch --app-like`, frontmost | 0.600 % | 0.133 % |
| Engine, `--app-like --hidden` | — | 0.050 % |
| Whole app, release, scratch home, 1 pane | 0.900 % | 0.650 % |

The remaining engine work is the 4 s system scan (`KERN_PROC_ALL` plus a `stat` per Claude
status file) and the 5 s safety poll. In the whole-app profile, the engine is now about a
quarter of the samples. The rest is the pane's terminal renderer and Metal submissions,
plus the app's port scan, which reads its own `KERN_PROC_ALL` every 5 s.
