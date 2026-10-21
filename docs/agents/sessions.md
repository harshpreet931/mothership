# Persistent sessions (`mshipd`)

Shells and agents keep running when Mothership quits, crashes or is `kill -9`ed, and the next
launch reattaches every saved pane with its screen and scrollback. No tmux: a small daemon,
`mshipd`, owns the PTYs, and the app renders them through libghostty's in-memory backend.

```
Mothership.app ──unix socket (sessions.sock)──► mshipd ──PTY──► -zsh / claude / npm run dev …
  TerminalSurfaceController                        per session: process, 6 MB output ring,
  (.inMemory(InMemoryTerminalSession))             DEC-mode tracker, attached clients
```

## Pieces

| Where | What |
|---|---|
| `Sources/SessionHost` | Protocol (framing, messages), `OutputRingBuffer`, `TerminalModeTracker`, `PTYSpawner`, `SessionHostServer` (the daemon core), `SessionHostClient`, `SessionHostLauncher`, `SessionHostPaths`. Shared by the app and the daemon; tested in `SessionHostTests`. |
| `Sources/mshipd` | `--serve` (the host), `--launch` (start it detached), `--list` (diagnostics), `--exec-child` (PTY trampoline). |
| `Sources/TerminalEngine` | `TerminalSurfaceController(sessionHost:reattach:)`: the persistent backend and replay gate. `PersistentShell.spec`: argv + environment for daemon-spawned shells. |
| `Sources/MothershipApp/Model/AppModel+Sessions.swift` | The setting, connect-or-launch, version policy, reconnect, quit behavior, ⌥⌘Q. |

## Lifecycle

- **Launch.** Before restoring the layout the app connects to `sessions.sock` (next to
  `control.sock`; long scratch homes fall back to a short temp path derived the same way, see
  `SessionHostPaths`). If nothing listens it runs `mshipd --launch`, which spawns `mshipd --serve`
  as its own session (`setsid`) and exits; the host is reparented to launchd, so nothing that
  happens to the app reaches it and the app never leaves a zombie.
- **New pane.** `open(id = SurfaceID, attachIfExists: false, spawn: spec, cols, rows)`. The open
  is sent once the Ghostty surface exists, at its first real grid size, so replayed bytes never
  land in libghostty's 1 MiB pre-attach buffer and a TUI never starts at 80×24.
- **Restored pane.** `open(attachIfExists: true, spawn: spec)`: one round trip that reattaches a
  live session (replay, then live output) or starts a fresh shell in the saved cwd. Reattached
  panes drop the resume banner (their agent is still running); fresh ones keep it.
- **Quit (keep-alive on).** Panes `detach()`; sessions keep running and buffering. No quit
  confirmation: nothing stops. `kill -9` or a crash is the same from the host's side (the socket
  closes, the sessions stay).
- **Close a pane or workspace.** `close(id)`: SIGHUP to the foreground group and the session's
  process group, SIGKILL after 3 s if it lingers.
- **Quit and End All Sessions (⌥⌘Q).** Asks while agents or commands run, then closes every
  session and quits.
- **Idle exit.** The host exits 10 s after its last session ended while no client is attached.
- **Host crash.** Its PTYs close with it (the shells get SIGHUP). The app notices the dropped
  connection, starts a new host and gives each pane a fresh shell under its existing screen.

## Setting

`UserDefaults` key `sessions.keepAlive`, default true (Settings → General, "Keep sessions running
when Mothership quits"). Off means the old behavior: panes run under the app (`.exec`), quit asks
while something runs, and shells die with the app; sessions left in a running host from an
earlier run are ended at launch. `MOTHERSHIP_KEEP_SESSIONS=0|1` overrides it for one run without
touching the stored value (QA). Demo mode never uses the host.

## Protocol

Frames: 4-byte big-endian length, 1-byte type, payload. Output/input frames are binary
(16-byte session UUID, then bytes; output carries the 8-byte stream offset of its first byte);
everything else is JSON. Unknown types are skipped.

| Type | Direction | Payload |
|---|---|---|
| `hello` 0x01 / `welcome` 0x02 | → / ← | version, client name, pid / version, host pid, session count |
| `open` 0x10 | → | requestID, session, attachIfExists, spawn spec?, cols, rows, fromOffset |
| `opened` 0x11 | ← | requestID, session, created, pid, outputOffset |
| `output` 0x20 | ← | session, offset, bytes (replay first, then live) |
| `replayEnd` 0x12 | ← | session, mode-restore suffix |
| `input` 0x21, `resize` 0x22 | → | session, bytes / cols, rows, pixels |
| `flow` 0x23 | → | session, paused (client backpressure) |
| `detach` 0x24, `close` 0x25, `signal` 0x26 | → | session (+ signal) |
| `exited` 0x30 | ← | session, exit code, signal |
| `list` 0x40 / `sessions` 0x41 | → / ← | requestID / session infos |
| `shutdown` 0x50 | → | end every session and exit |
| `error` 0x7F | ← | requestID?, session?, code, message |

**Versioning.** `SessionProtocol.version` (1). The hello/welcome shape never changes, so a
mismatch is always visible. A newer app finding an older host with no sessions shuts it down and
starts its own; with sessions it leaves it running (killing them would be the one thing this
feature promises not to do), logs it, and new panes run under the app until that host exits.

## Decisions

- **Spawning without `fork`.** Forking a multithreaded Swift process and running anything but
  async-signal-safe code before `exec` can deadlock. `posix_spawn` starts `mshipd --exec-child`
  with `POSIX_SPAWN_SETSID | SETSIGDEF | SETSIGMASK | CLOEXEC_DEFAULT` and the slave as fds 0–2;
  the trampoline does `TIOCSCTTY`, `chdir`, `execve`. The child is a session leader whose
  controlling terminal is the PTY, exactly what a terminal gives a shell (tested).
- **The app computes the environment.** `PersistentShell.spec` reproduces what Ghostty's exec
  backend adds (`TERM=xterm-ghostty`, `TERMINFO`, `COLORTERM`, `TERM_PROGRAM[_VERSION]`,
  `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`, `GHOSTTY_SHELL_FEATURES`, `MANPATH`,
  `XDG_DATA_DIRS`) and its shell integration (zsh through `ZDOTDIR` with the user's in
  `GHOSTTY_ZSH_ZDOTDIR`; bash 4+ through `--posix` + `ENV`), scrubbed of inherited host markers
  (`InheritedEnvironment`). The daemon itself runs with a minimal environment and just spawns.
  Shells start as login shells (`argv[0] = "-zsh"`), without `login(1)`, so there's no
  "Last login" line. Startup commands still go through the `ShellLaunch` wrapper via `/bin/sh -c`,
  as Ghostty runs `command`.
- **Replay that doesn't type.** Replayed output can contain queries (DA `ESC [ c`, DSR…) that the
  terminal answers by writing input. Until `InMemoryTerminalSession.waitForPendingOutput()`
  confirms the replay was parsed, the write path drops everything, and replayed bells,
  notifications and progress are ignored (title and cwd are kept). Keys typed during the few
  milliseconds of replay are dropped too.
- **TUIs across a wrapped buffer.** The ring keeps the last 6 MB. A fresh replay that starts mid
  stream starts at a line boundary. `TerminalModeTracker` follows DEC private modes; if the switch
  to the alternate screen scrolled out, the replay ends with `ESC [?1049h` plus the live key/mouse/
  paste modes, and the host nudges the program (two `TIOCSWINSZ`) so it repaints.
- **Reconnects replay only what's missing** (`fromOffset`), so a host restart within one app
  run doesn't duplicate the screen.
- **Backpressure.** A client more than 8 MB behind pauses the session's PTY reads (the program
  blocks on write) until it's under 2 MB; clients can also pause explicitly (`flow`).
- **One serial queue, Dispatch sources.** No polling: an idle host uses no CPU. A partially
  drained PTY re-queues its read (readiness isn't re-signalled for data already pending).

## Measured

On an M-series Mac, debug build, host in-process (SessionHostTests):

| | p50 | p95 |
|---|---|---|
| Keystroke echo, direct PTY | 4.9 µs | 7.7 µs |
| Keystroke echo through mshipd | 35 µs | 87 µs |
| **Extra round trip** | **30 µs** | **79 µs** |

Throughput in that debug test (50 MB through the PTY): 20 MB/s reading the PTY directly, 25 MB/s
through mshipd, so the host isn't the bottleneck there.

In the bundled release app (`scripts/qa.sh` instance), `cat` of a 70 MB file of 47-byte lines
into a pane, all the way to the screen:

| | `cat` wall time | control pings meanwhile (main thread) |
|---|---|---|
| Persistence off (`.exec`) | 0.33 s | p50 8 ms, max 21 ms |
| Through mshipd | 0.38–0.70 s (100–185 MB/s) | p50 11 ms, max 16 ms |

The UI keeps answering throughout. Idle host with three idle shells: 0.00 s of CPU over 30 s, 0 idle
wakeups (`top`): no timers or polling while sessions are quiet.

## Verifying

`scripts/qa.sh` drives a scratch instance (its own `MOTHERSHIP_HOME`, one scratch root per
checkout) through every case: a counter survives a graceful quit and `kill -9` and keeps counting,
scrollback comes back, `less` redraws and takes keys, a replayed DA query injects nothing, `tput
cols` follows the pane after reattach and after a split, closing panes ends sessions and the host
then exits, and with persistence off quit asks again and shells die with the app. `qa.sh restart`
quits and relaunches by hand; `mshipd --list --socket PATH` prints the host's sessions as JSON.

## Limits and gaps

- A host crash loses its sessions (the PTYs close with it); the panes get fresh shells.
- Queries a program makes while no app is attached (e.g. vim started while Mothership was closed)
  go unanswered until it reattaches.
- After Ctrl-C during replay or reattach, keys typed in the first few milliseconds are dropped.
- Scrollback older than the 6 MB ring is gone after a relaunch (the screen and recent history
  come back).
- Shells start without `login(1)`: no utmp entry (`who` doesn't list them).
