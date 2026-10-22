#!/usr/bin/env bash
# End-to-end QA: builds and bundles Mothership, launches it against a scratch home (never the
# user's state, sockets or agent configs), drives it through `mship`, prints a PASS/FAIL table.
#
#   scripts/qa.sh              # bundle, launch, run every check, quit (exit 1 on any FAIL)
#   scripts/qa.sh --no-build   # reuse build/Mothership.app
#   scripts/qa.sh up           # bundle + launch only, for poking at it by hand
#   scripts/qa.sh mship ARGS…  # run mship against the instance `up` started
#   scripts/qa.sh down         # quit that instance and its session host
#   scripts/qa.sh restart      # quit gracefully and relaunch (persistent panes reattach)
#
# Shells in the QA instance use a scratch ZDOTDIR whose .zshrc draws a fake "instant
# prompt" immediately and then keeps loading for a second (p10k-style), so every check also
# exercises the shell-readiness gate. Only processes this script started are ever killed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# One scratch root per checkout: runs from different worktrees never share a pid file, home
# or session host.
QA_ROOT="${MOTHERSHIP_QA_ROOT:-${TMPDIR:-/tmp}/mothership-qa-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)}"
# Normalized (TMPDIR ends in "/"), so paths compare equal to what shells report.
QA_ROOT="$(printf '%s' "$QA_ROOT" | tr -s /)"
QA_ROOT="${QA_ROOT%/}"
APP="$ROOT/build/Mothership.app"
BIN="$APP/Contents/MacOS/Mothership"
MSHIP="$APP/Contents/MacOS/mship"
PIDFILE="$QA_ROOT/app.pid"
HOME_DIR="$QA_ROOT/home"
ZDOT="$QA_ROOT/zdot"
WORK="$QA_ROOT/work"
LOG="$QA_ROOT/app.log"

build=1
command="run"
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        up|down|run|mship|restart) command="$arg"; break ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    esac
done

# --- environment -------------------------------------------------------------------------

qa_env() {
    # Never inherit a real Mothership's socket/pane identity.
    env -u MOTHERSHIP_SOCKET -u MOTHERSHIP_SURFACE_ID -u MOTHERSHIP_WORKSPACE_ID \
        MOTHERSHIP_HOME="$HOME_DIR" ZDOTDIR="$ZDOT" NO_COLOR=1 "$@"
}

ms() { qa_env "$MSHIP" "$@"; }

# Starts the app in the background with $! = the app itself (`env` execs it in place; a
# backgrounded shell function would leave $! pointing at a subshell and orphan the app).
# QA_KEEP=0 runs with persistent sessions off (never touching the stored preference).
start_app() {
    env -u MOTHERSHIP_SOCKET -u MOTHERSHIP_SURFACE_ID -u MOTHERSHIP_WORKSPACE_ID \
        MOTHERSHIP_HOME="$HOME_DIR" ZDOTDIR="$ZDOT" NO_COLOR=1 MOTHERSHIP_KEEP_SESSIONS="${QA_KEEP:-1}" \
        MOTHERSHIP_TEST_WINDOW=corner MOTHERSHIP_DEBUG_QUIT_ANSWER="${QA_QUIT_ANSWER:-cancel}" \
        "$BIN" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    disown "$!" 2>/dev/null || true
}

# A Quit Apple event to exactly this pid (JXA). The QA app shares the real app's bundle id,
# so it must never be addressed by name or bundle id.
quit_event() {
    osascript -l JavaScript -e 'ObjC.import("AppKit")
function run(argv) {
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[0]));
  return app.isNil() ? "missing" : String(app.terminate);
}' "$1" >/dev/null 2>&1
}
graceful_quit_pid() {
    quit_event "$1"
    for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}

relaunch() {
    start_app
    APP_PID="$(cat "$PIDFILE")"
    for _ in $(seq 1 100); do ms ping -q 2>/dev/null && return 0; sleep 0.1; done
    return 1
}

# This run's session host: the pid its own log announced, and only if it's our build's mshipd.
DAEMON_BIN="$APP/Contents/MacOS/mshipd"
daemon_line() { grep -a 'listening on' "$HOME_DIR/mshipd.log" 2>/dev/null | tail -1; }
daemon_pid() {
    local pid; pid="$(daemon_line | sed -nE 's/.*mshipd\[([0-9]+)\].*/\1/p')"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(ps -o comm= -p "$pid")" == "$DAEMON_BIN" ]] && echo "$pid"
}
daemon_socket() { daemon_line | sed -nE 's/.*listening on (.*) \(protocol.*/\1/p'; }
daemon_sessions() {
    local socket; socket="$(daemon_socket)"
    [[ -n "$socket" ]] || return 1
    "$DAEMON_BIN" --list --socket "$socket" 2>/dev/null
}
daemon_session_count() { daemon_sessions | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"]))' 2>/dev/null || echo 0; }
daemon_session_pid() {
    daemon_sessions | python3 -I -c 'import json,sys
for s in json.load(sys.stdin)["sessions"]:
    if s["session"] == sys.argv[1]: print(s["pid"])' "$1" 2>/dev/null
}
stop_daemon() {
    local pid; pid="$(daemon_pid)"
    [[ -n "$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null
}

prepare_dirs() {
    rm -rf "$HOME_DIR" "$WORK"
    mkdir -p "$HOME_DIR" "$ZDOT" "$WORK/plain" "$WORK/twin" "$WORK/repo/src"
    # Like powerlevel10k's instant prompt: draw a prompt and turn bracketed paste on right
    # away, then keep loading. Input that arrives now is echoed by the tty, markers and all.
    cat > "$ZDOT/.zshrc" <<'RC'
print -n -- $'fake-instant-prompt > \e[?2004h'
sleep "${QA_RC_DELAY:-2}"
PROMPT='qa> '
RC
    : > "$ZDOT/.zshenv"
    seq -f 'qa-line %g' 1 400 > "$WORK/long.txt"
    git -C "$WORK/repo" init -q 2>/dev/null || mkdir -p "$WORK/repo/.git"
    cat > "$WORK/page.html" <<'HTML'
<!doctype html><title>QA Page</title>
<h1>QA heading</h1>
<button id="go" onclick="document.getElementById('out').textContent = 'clicked:' + (1 + 1)">Go</button>
<p id="out">idle</p>
HTML
}

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

launch() {
    if is_running; then echo "QA instance already running (pid $(cat "$PIDFILE"))"; return 0; fi
    stop_daemon
    prepare_dirs
    : > "$LOG"
    start_app
    for _ in $(seq 1 100); do
        if ms ping -q 2>/dev/null; then echo "QA instance up (pid $(cat "$PIDFILE"))"; return 0; fi
        sleep 0.1
    done
    echo "QA instance didn't answer ping; log: $LOG" >&2
    return 1
}

quit() {
    is_running || { rm -f "$PIDFILE"; return 0; }
    local pid; pid="$(cat "$PIDFILE")"
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    rm -f "$PIDFILE"
}

bundle() {
    [[ "$build" == 1 ]] || { [[ -x "$BIN" ]] || { echo "no $BIN; run without --no-build" >&2; exit 2; }; return; }
    "$ROOT/scripts/bundle.sh" >"$QA_ROOT.bundle.log" 2>&1 || { tail -30 "$QA_ROOT.bundle.log" >&2; exit 2; }
}

case "$command" in
    up) mkdir -p "$QA_ROOT"; bundle; launch; exit $? ;;
    down) quit; stop_daemon; exit 0 ;;
    restart)
        APP_PID="$(cat "$PIDFILE" 2>/dev/null)"
        [[ -n "$APP_PID" ]] && graceful_quit_pid "$APP_PID"
        relaunch && echo "QA instance up (pid $APP_PID)"; exit $? ;;
    mship) shift_args=(); seen=0
        for arg in "$@"; do if [[ $seen == 1 ]]; then shift_args+=("$arg"); elif [[ "$arg" == mship ]]; then seen=1; fi; done
        ms "${shift_args[@]}"; exit $? ;;
esac

# --- check helpers -------------------------------------------------------------------------

NAMES=(); RESULTS=(); DETAILS=()
record() { NAMES+=("$1"); RESULTS+=("$2"); DETAILS+=("${3:-}"); }
pass() { record "$1" PASS "${2:-}"; }
fail() { record "$1" FAIL "${2:-}"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name" "${DETAIL:-}"; fi; DETAIL=""; }

screen() { ms screen --surface "$1" --lines "${2:-200}" 2>/dev/null; }

# wait_for SURFACE REGEX [SECONDS]: poll the pane's text until it matches.
wait_for() {
    local deadline=$((SECONDS + ${3:-10}))
    while (( SECONDS < deadline )); do
        screen "$1" | grep -Eq -- "$2" && return 0
        sleep 0.3
    done
    DETAIL="no /$2/ in: $(screen "$1" | tail -4 | tr '\n' '|' | cut -c1-160)"
    return 1
}

count_lines() { screen "$1" | grep -Ec -- "$2"; }

no_paste_artifacts() {
    local text; text="$(screen "$1")"
    if printf '%s' "$text" | grep -Eq $'\e|\\^\\[\\[|20[01]~'; then
        DETAIL="paste markers on screen: $(printf '%s' "$text" | grep -E $'\e|\\^\\[\\[|20[01]~' | head -2 | tr '\n' '|')"
        return 1
    fi
}

status_json() { ms status --json 2>/dev/null; }
workspace_names() { status_json | python3 -I -c 'import json,sys; print("\n".join(w["name"] for w in json.load(sys.stdin)["workspaces"]))'; }
surfaces_of_workspace_with() {
    status_json | python3 -I -c 'import json,sys
d = json.load(sys.stdin)
for w in d["workspaces"]:
    if sys.argv[1] in w["surfaces"]: print(" ".join(w["surfaces"]))' "$1"
}

saved_cwd() {
    python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
for win in d["windows"]:
    for w in win["workspaces"]:
        for s in w["surfaces"]:
            if s["id"] == sys.argv[2]: print(s.get("cwd", ""))' "$HOME_DIR/state.json" "$1" 2>/dev/null
}

# A Quit Apple event to exactly this pid (JXA). The QA app shares the real app's bundle id,
# so it must never be addressed by name or bundle id.
ask_to_quit() {
    osascript -l JavaScript -e 'ObjC.import("AppKit")
function run(argv) {
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[0]));
  return app.isNil() ? "missing" : String(app.terminate);
}' "$1" >/dev/null 2>&1
}
alive() { kill -0 "$1" 2>/dev/null; }
wait_exit() { local deadline=$((SECONDS + $2)); while (( SECONDS < deadline )); do alive "$1" || return 0; sleep 0.2; done; return 1; }

print_table() {
    local failures=0 i
    printf '\n%-46s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
    printf '%-46s %-6s %s\n' "-----" "------" "------"
    for i in "${!NAMES[@]}"; do
        printf '%-46s %-6s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]:0:120}"
        [[ "${RESULTS[$i]}" == PASS ]] || failures=$((failures + 1))
    done
    printf '\n%d checks, %d failed\n' "${#NAMES[@]}" "$failures"
    return $((failures > 0))
}

# --- run -----------------------------------------------------------------------------------

mkdir -p "$QA_ROOT"
quit
stop_daemon
bundle
trap 'quit; stop_daemon' EXIT
DETAIL=""

if launch >/dev/null; then pass "launch with scratch home" "pid $(cat "$PIDFILE")"; else fail "launch with scratch home" "see $LOG"; print_table; exit 1; fi
APP_PID="$(cat "$PIDFILE")"

# 1. A workspace whose pane starts with a command: run once, no typing, then a shell.
S1="$(ms new --cwd "$WORK/plain" -- 'echo qa-cmd-$((6*7)) && echo "qa two words"')"
# (The `-c` shell runs the rc too, so output can follow the fake instant prompt on its line.)
check "new workspace runs its command" wait_for "$S1" '(^|> )qa-cmd-42$' 10
check "  command ran exactly once" test "$(count_lines "$S1" '(^|> )qa-cmd-42$')" = 1
check "  quoting survived" wait_for "$S1" '(^|> )qa two words$' 2
check "  nothing typed (command line not echoed)" test "$(count_lines "$S1" 'echo qa-cmd')" = 0
check "  no paste markers on screen" no_paste_artifacts "$S1"
check "  pane becomes an interactive shell" wait_for "$S1" '^qa>' 8
ms send --surface "$S1" --submit 'echo qa-after-$((1+1))' >/dev/null
check "  shell takes input after the command" wait_for "$S1" '^qa-after-2' 6
ms send --surface "$S1" --submit "cd '$WORK/repo/src'" >/dev/null
sleep 2.5
SAVED="$(saved_cwd "$S1")"
DETAIL="saved cwd: ${SAVED:-none}"
check "  shell integration after exec (OSC 7 cwd)" eval '[[ "$SAVED" == "$WORK/repo/src" || "$SAVED" == "/private$WORK/repo/src" ]]'

# A workspace started in the background (MCP workspace_new's default) still runs its command.
SBG="$(ms new --background --cwd "$WORK/plain" -- 'echo qa-bg-$((2+2))')"
check "background workspace runs its command" wait_for "$SBG" '(^|> )qa-bg-4$' 10

# 2. Splits.
S2="$(ms split --surface "$S1" --right)"
check "split right adds a pane" eval '[[ " $(surfaces_of_workspace_with "$S1") " == *" $S2 "* ]]'
S3="$(ms split --surface "$S1" --down)"
check "split down adds a pane" eval '[[ " $(surfaces_of_workspace_with "$S1") " == *" $S3 "* ]]'

# 3. Readiness: text sent while the new shell's rc is still loading (fake instant prompt).
ms send --surface "$S3" --submit 'echo qa-ready-$((7*6))' >/dev/null
check "send while rc loads waits for the prompt" wait_for "$S3" '^qa-ready-42' 10
check "  input ran exactly once" test "$(count_lines "$S3" '^qa-ready-42')" = 1
check "  not echoed during rc load" test "$(count_lines "$S3" 'fake-instant-prompt.*qa-ready')" = 0
check "  no paste markers on screen" no_paste_artifacts "$S3"
ms send --surface "$S2" --submit 'printf "qa-multi\nline\n" | wc -l | tr -d " "' >/dev/null
check "send to the right pane" wait_for "$S2" '^2$' 10
check "screen with scrollback" eval '[[ -n "$(screen "$S2" 50)" ]]'

# 4. Ctrl-C on the started command leaves a working shell (SIGINT to its process group).
S4="$(ms new --cwd "$WORK/plain" -- 'sleep 31337')"
sleep 3
SLEEP_PID="$(pgrep -f '^sleep 31337$' | head -1)"
if [[ -n "$SLEEP_PID" ]]; then
    kill -INT -- "-$(ps -o pgid= -p "$SLEEP_PID" | tr -d ' ')" 2>/dev/null
    sleep 1
    ms send --surface "$S4" --submit 'echo qa-alive-$((40+2))' >/dev/null
    check "Ctrl-C on the command leaves a shell" wait_for "$S4" '^qa-alive-42' 8
else
    fail "Ctrl-C on the command leaves a shell" "sleep 31337 not found"
fi

# 5. Browser: open a local page, snapshot, click, eval.
B="$(ms open --split "file://$WORK/page.html" 2>&1)"
sleep 2
SNAP="$(ms browser snapshot --browser "$B" 2>&1)"
check "open + browser snapshot" eval 'grep -q "heading \"QA heading\"" <<<"$SNAP"'
REF="$(grep -o 'button "Go"[^]]*\[ref=e[0-9]*\]' <<<"$SNAP" | grep -o 'e[0-9]*' | tail -1)"
ms browser click --browser "$B" "${REF:-#go}" >/dev/null 2>&1
check "browser click + eval" eval '[[ "$(ms browser eval --browser "$B" "document.getElementById(\"out\").textContent" 2>&1)" == "clicked:2" ]]'

# 6. Status.
check "status table" eval 'ms status | grep -q "workspace"'
check "status --json" eval 'status_json | python3 -I -c "import json,sys; json.load(sys.stdin)[\"workspaces\"]"'

# 7. Names: meaningful and unique.
ms new --cwd "$WORK/twin" >/dev/null
ms new --cwd "$WORK/twin" >/dev/null
ms new --cwd "$WORK/repo/src" >/dev/null
ms new --cwd "$WORK/twin" --name "QA Custom" >/dev/null
ms new --cwd "$HOME" >/dev/null
sleep 1
NAMES_NOW="$(workspace_names)"
check "names: a second workspace in ~ is \"Home 2\"" eval 'grep -qx "Home 2" <<<"$NAMES_NOW"'
check "names: two in one folder are deduped" eval 'grep -qx "twin" <<<"$NAMES_NOW" && grep -qx "twin 2" <<<"$NAMES_NOW"'
check "names: git repo name for a subfolder" eval 'grep -qx "repo" <<<"$NAMES_NOW"'
check "names: first workspace is Home" eval '[[ "$(head -1 <<<"$NAMES_NOW")" == "Home" ]]'
check "names: custom name kept" eval 'grep -qx "QA Custom" <<<"$NAMES_NOW"'
check "names: all unique" eval '[[ "$(sort <<<"$NAMES_NOW" | uniq -d)" == "" ]]'

last_tick() { screen "$1" 400 | sed -nE 's/^qa-tick ([0-9]+)$/\1/p' | tail -1; }
graceful_quit() { graceful_quit_pid "$APP_PID"; }
gone_within() { local deadline=$((SECONDS + $2)); while (( SECONDS < deadline )); do alive "$1" || return 0; sleep 0.5; done; return 1; }

# 8. Persistent sessions: mshipd owns the PTYs, so panes outlive the app.
# 300 lines first, so the oldest ones are only in scrollback.
C="$(ms new --cwd "$WORK/plain" --name "QA Counter" -- 'seq -f "qa-old %g" 1 300; n=0; while :; do n=$((n+1)); echo "qa-tick $n"; sleep 0.5; done')"
L="$(ms new --cwd "$WORK/plain" --name "QA Pager" -- "less $WORK/long.txt")"
D="$(ms new --cwd "$WORK/plain" --name "QA Query")"
check "persistent: a counter runs" wait_for "$C" '^qa-tick 4$' 10
check "persistent: a full-screen TUI (less) is up" wait_for "$L" '^qa-line 1$' 10
wait_for "$D" '^qa>' 10 >/dev/null
# A DA query answered live (the shell reads the reply), so its bytes sit in the replay buffer.
ms send --surface "$D" --submit "printf '\033[c'; read -rs -t 2 -d c reply; echo qa-da-answered-\${#reply}" >/dev/null
check "persistent: terminal answers a live DA query" wait_for "$D" '^qa-da-answered-[1-9]' 6
DAEMON="$(daemon_pid)"
C_PID="$(daemon_session_pid "$C")"
DETAIL="mshipd ${DAEMON:-none}, counter session pid ${C_PID:-none}"
check "persistent: panes run under mshipd" eval '[[ -n "$DAEMON" && -n "$C_PID" && "$(ps -o ppid= -p "$C_PID" | tr -d " ")" == "$DAEMON" ]]'
SESSIONS_BEFORE="$(daemon_session_count)"
TICK_BEFORE="$(last_tick "$C")"
NAMES_NOW="$(workspace_names)"

check "quit with persistence on doesn't ask" graceful_quit
DETAIL="sessions: $(daemon_session_count) of $SESSIONS_BEFORE"
check "  sessions keep running in mshipd" eval '[[ "$(daemon_session_count)" == "$SESSIONS_BEFORE" && "$SESSIONS_BEFORE" -gt 0 ]]'
sleep 3
relaunch
check "  relaunch reattaches the same surface" wait_for "$C" '^qa-tick [0-9]+$' 12
sleep 1
T1="$(last_tick "$C")"; sleep 1.5; T2="$(last_tick "$C")"
DETAIL="tick before quit ${TICK_BEFORE:-?}, after relaunch ${T1:-?} then ${T2:-?}"
check "  counter kept counting while the app was gone" eval '(( ${T1:-0} > ${TICK_BEFORE:-0} + 4 && ${T2:-0} > ${T1:-0} ))'
# (The first line follows the scratch .zshrc's fake prompt.)
check "  older lines are in scrollback" eval 'screen "$C" 3000 | grep -qE "(^|> )qa-old 1$" && ! screen "$C" 0 | grep -qE "(^|> )qa-old 1$"'
RESTORED_NAMES="$(workspace_names)"
check "restore keeps workspace names" eval '[[ -z "$(comm -23 <(sort <<<"$NAMES_NOW") <(sort <<<"$RESTORED_NAMES"))" ]]'
check "  full-screen TUI redraws after reattach" eval 'wait_for "$L" "^qa-line 1$" 6 && ! screen "$L" 0 | grep -q "^qa>"'
ms send --surface "$L" q >/dev/null
check "  the TUI still takes keys (q quits less)" wait_for "$L" '^qa>' 8
# Replaying `ESC [ c` makes the terminal answer again; that answer must not reach the shell.
sleep 1
ms send --surface "$D" --submit 'echo qa-after-replay' >/dev/null
wait_for "$D" '^qa-after-replay$' 8 >/dev/null
DETAIL="prompt line: $(screen "$D" | grep -E 'echo qa-after-replay' | head -1)"
check "  replay injects no stray input (old DA answer)" eval 'screen "$D" | grep -qx "qa> echo qa-after-replay"'
# The PTY has the pane's size after reattach (a full-width ruler fits on one row) and follows a split.
ruler() { ms send --surface "$D" --submit 'c=$(tput cols); printf "%${c}s\n" "|" | tr " " "#"; echo qa-cols=$c' >/dev/null; sleep 1.5; }
ruler_cols() {
    local cols row
    cols="$(screen "$D" | sed -nE 's/^qa-cols=([0-9]+)$/\1/p' | tail -1)"
    row="$(screen "$D" | grep -E '^#+\|$' | tail -1)"
    [[ -n "$cols" && "${#row}" == "$cols" ]] && echo "$cols"
}
ruler
COLS1="$(ruler_cols)"
DETAIL="tput cols vs ruler row: $(screen "$D" | sed -nE 's/^qa-cols=([0-9]+)$/\1/p' | tail -1) vs $(screen "$D" | grep -E '^#+\|?$' | tail -1 | wc -c | tr -d ' ')"
check "  resize: tput cols matches the pane after reattach" test -n "$COLS1"
ms split --surface "$D" --right >/dev/null
sleep 2
ruler
COLS2="$(ruler_cols)"
DETAIL="cols ${COLS1:-?} then ${COLS2:-?}"
check "  resize: a split narrows the reattached PTY" eval '[[ -n "$COLS2" && "$COLS2" -lt "${COLS1:-0}" ]]'

# kill -9 mid-session: the host keeps the sessions; relaunch reattaches.
T3="$(last_tick "$C")"
kill -KILL "$APP_PID" 2>/dev/null
wait_exit "$APP_PID" 5
sleep 2
relaunch
check "kill -9 the app: relaunch reattaches" wait_for "$C" '^qa-tick [0-9]+$' 12
sleep 1
T4="$(last_tick "$C")"
DETAIL="tick before kill ${T3:-?}, after ${T4:-?}"
check "  the counter survived the crash" eval '(( ${T4:-0} > ${T3:-0} + 3 ))'

# Closing a pane ends its session; with no sessions and no client the host exits.
L_PID="$(daemon_session_pid "$L")"
ms close --surface "$L" >/dev/null
sleep 1.5
DETAIL="less session pid ${L_PID:-?}"
check "closing a pane ends its session" eval '[[ -n "$L_PID" && -z "$(daemon_session_pid "$L")" ]] && ! alive "$L_PID"'
for surface in $(status_json | python3 -I -c 'import json,sys; print(" ".join(s for w in json.load(sys.stdin)["workspaces"] for s in w["surfaces"]))'); do
    ms close --surface "$surface" >/dev/null 2>&1
done
sleep 1
DAEMON="$(daemon_pid)"
graceful_quit
DETAIL="mshipd ${DAEMON:-none}"
check "  the host exits after its last session" eval '[[ -n "$DAEMON" ]] && gone_within "$DAEMON" 16'

# 9. Persistence off: the old behavior. Quit asks, and shells die with the app.
QA_KEEP=0 relaunch
ms new --cwd "$WORK/plain" -- 'sleep 31338' >/dev/null
sleep 3
OFF_PID="$(pgrep -f '^sleep 31338$' | head -1)"
DETAIL="mshipd: $(daemon_pid || echo none), sleep ${OFF_PID:-none}"
check "persistence off: panes run under the app" eval '[[ -z "$(daemon_pid)" && -n "$OFF_PID" ]]'
quit_event "$APP_PID"
sleep 3
ASKED="$(grep -a 'asking before quit' "$LOG" | tail -1 | sed 's/.*asking before quit: //')"
DETAIL="prompt: ${ASKED:-none}"
check "quit with a running command asks first" eval 'alive "$APP_PID" && [[ "$ASKED" == *"command"* ]]'
quit
sleep 1
check "  persistence off: shells die with the app" eval '[[ -n "$OFF_PID" ]] && ! alive "$OFF_PID"'

# Restore with persistence off; quitting with only idle shells doesn't ask.
QA_KEEP=0 relaunch
# Let the restored shells finish their (slow) rc files: while `sleep` in .zshrc runs it is
# the pane's foreground job, which would rightly count as running.
sleep 4
quit_event "$APP_PID"
check "quit with idle shells doesn't ask" wait_exit "$APP_PID" 8
rm -f "$PIDFILE"

print_table
