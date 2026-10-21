#!/usr/bin/env bash
# End-to-end QA: builds and bundles Mothership, launches it against a scratch home (never the
# user's state, sockets or agent configs), drives it through `mship`, prints a PASS/FAIL table.
#
#   scripts/qa.sh              # bundle, launch, run every check, quit (exit 1 on any FAIL)
#   scripts/qa.sh --no-build   # reuse build/Mothership.app
#   scripts/qa.sh up           # bundle + launch only, for poking at it by hand
#   scripts/qa.sh mship ARGS…  # run mship against the instance `up` started
#   scripts/qa.sh down         # quit that instance
#
# Shells in the QA instance use a scratch ZDOTDIR whose .zshrc draws a fake "instant
# prompt" immediately and then keeps loading for a second (p10k-style), so every check also
# exercises the shell-readiness gate. Only processes this script started are ever killed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QA_ROOT="${MOTHERSHIP_QA_ROOT:-${TMPDIR:-/tmp}/mothership-qa}"
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
        up|down|run|mship) command="$arg"; break ;;
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
start_app() {
    env -u MOTHERSHIP_SOCKET -u MOTHERSHIP_SURFACE_ID -u MOTHERSHIP_WORKSPACE_ID \
        MOTHERSHIP_HOME="$HOME_DIR" ZDOTDIR="$ZDOT" NO_COLOR=1 "$BIN" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    disown "$!" 2>/dev/null || true
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
    down) quit; exit 0 ;;
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
bundle
trap 'quit' EXIT
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

# 8. Quit asks while something runs.
ms new --cwd "$WORK/plain" -- 'sleep 31338' >/dev/null
sleep 3
ask_to_quit "$APP_PID"
sleep 3
ASKED="$(grep -a 'asking before quit' "$LOG" | tail -1 | sed 's/.*asking before quit: //')"
DETAIL="prompt: ${ASKED:-none}"
check "quit with a running command asks first" eval 'alive "$APP_PID" && [[ "$ASKED" == *"command"* ]]'
quit

# 9. Restore keeps names; quitting with only idle shells doesn't ask.
start_app
APP_PID="$(cat "$PIDFILE")"
for _ in $(seq 1 100); do ms ping -q 2>/dev/null && break; sleep 0.1; done
# Let the restored shells finish their (slow) rc files: while `sleep` in .zshrc runs it is
# the pane's foreground job, which would rightly count as running.
sleep 4
RESTORED_NAMES="$(workspace_names)"
check "restore keeps workspace names" eval '[[ -z "$(comm -23 <(sort <<<"$NAMES_NOW") <(sort <<<"$RESTORED_NAMES"))" ]]'
ask_to_quit "$APP_PID"
check "quit with idle shells doesn't ask" wait_exit "$APP_PID" 8
rm -f "$PIDFILE"

print_table
