#!/usr/bin/env bash
# scripts/tui-graceful-restart.sh
#
# Restart the TUI surface onto a freshly built binary, and prove the old
# session ended gracefully on its way out.
#
# The TUI is its own binary (docs/TUI-GUIDE "Troubleshooting"): start-masc.sh
# restarts the server and never touches the TUI, so after `dune build
# bin/masc_tui.exe` the running surface is stale until somebody quits and
# reopens it -- by hand. That hand quit is this script, and it keeps the
# proof the TUI already writes for itself: #37949 gave every session a
# per-PID exit log, so "ended gracefully" is a row the old process wrote,
# not a feeling:
#
#   [masc-tui] exit: normal (signal SIGTERM)
#
# Any `exit: normal (...)` row proves the end was asked for -- the
# vocabulary in bin/masc_tui_exit_reason.ml is a closed set (quit key,
# interrupt, signal NAME), so the prefix alone is the proof; the row is
# echoed so the reader sees which one it was.
#
# Usage:
#   scripts/tui-graceful-restart.sh [--build] [--timeout N] [--dry-run]
#                                   [--base-path PATH] [-- TUI-ARGS...]
#
#   --build       dune build bin/masc_tui.exe before touching anything;
#                 a failed build leaves the running session untouched.
#   --timeout N   whole seconds to wait for the old session to end after
#                 SIGTERM (default 10: the TUI gives a first SIGTERM a full
#                 finish, so a mid-turn session needs more than one refresh;
#                 a second SIGTERM would force an immediate end, and this
#                 script never sends one).
#   --dry-run     report what would happen; restart nothing.
#   --base-path P the base path for the fresh TUI and where per-PID exit
#                 logs are looked for (default: the checkout root).
#   -- ARGS...    everything after `--` is passed to the fresh instance.
#
# With no running TUI found the script starts a fresh one: restarting a
# surface that is not up is how the operator gets one back without a
# pane-scavenging hunt.
#
# Exit codes:
#   0   restarted (or --dry-run reported its plan)
#   1   an old session did not end within --timeout, or ended without a
#       graceful row; nothing new was started
#   2   the fresh session died within seconds of starting
#   3   the build failed (old session untouched)
#   4   usage error
#   78  EX_CONFIG: a required command is unavailable
#
# Self-test (no live TUI, no dune, no network; safe on any machine):
#   TUI_GRACEFUL_RESTART_SELF_TEST=1 scripts/tui-graceful-restart.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TUI_BINARY="$REPO_ROOT/_build/default/bin/masc_tui.exe"
# The process name (comm) is the exact identity: `masc_tui.exe` (12 chars,
# under the 15-char comm limit) on a source checkout, `masc-tui` when the
# install laid both names down together. Matching comm and only comm keeps
# a `tail -f .masc/logs/masc-tui-9.log` or an editor sitting on
# bin/masc_tui.ml from being read as a surface -- they open the log or the
# source, not the binary.
TUI_COMM_A="masc_tui.exe"
TUI_COMM_B="masc-tui"

BASE_PATH=""
TIMEOUT=10
DRY_RUN=0
DO_BUILD=0

log() { printf '[tui-restart] %s\n' "$*" >&2; }

find_surfaces() {
  # Compare on the basename: Linux `ps -o comm` gives the bare name, macOS
  # can give the full executable path, and both must read as the same
  # surface. Stripping any directory prefix also keeps a `tail -f
  # .../masc-tui-9.log` (comm `tail`) or an editor on bin/masc_tui.ml (comm
  # `less`) from matching -- they are not the binary.
  #
  # `stat` is read too, so a defunct surface is skipped. A zombie keeps its
  # comm and answers `kill -0` until its parent reaps it, so without this a
  # crashed TUI whose parent shell never waited reads as a live surface: it
  # would be discovered, signalled, outlast the whole --timeout, and block
  # every restart from then on. Observed: a defunct masc_tui.exe under ppid
  # 1 held this script off entirely.
  ps -axo pid=,stat=,comm= 2>/dev/null | awk -v a="$TUI_COMM_A" -v b="$TUI_COMM_B" '
    substr($2, 1, 1) == "Z" { next }
    { n = $3; sub(/.*\//, "", n); if (n == a || n == b) print $1 }'
}

# Does this pid name a process that is still doing something? `kill -0`
# alone does not answer that: it succeeds for a zombie, which exists in the
# process table but has already ended. Every "is it still there" question in
# this script means "still running", so all of them come through here.
is_zombie() {
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in
    Z*) return 0 ;;
    *) return 1 ;;
  esac
}

still_running() {
  kill -0 "$1" 2>/dev/null || return 1
  ! is_zombie "$1"
}

# The prefix of a graceful end's row. Any normal row counts; see header.
graceful_row_prefix='[masc-tui] exit: normal ('

# Read the exit row one old session left. Pure: no signals, no waiting.
#   0  its per-PID log carries a graceful row; the row is echoed on stdout
#   1  a log was found but no graceful row in it (the real last row is
#      reported on stderr)
#   2  no per-PID log found where the session would have written one
read_exit_row() {
  local pid="$1" candidate row
  for candidate in \
    "${BASE_PATH:+$BASE_PATH/}.masc/logs/masc-tui-$pid.log" \
    "$REPO_ROOT/.masc/logs/masc-tui-$pid.log"; do
    [ -f "$candidate" ] || continue
    row="$(grep -F "$graceful_row_prefix" "$candidate" | tail -n 1)"
    if [ -n "$row" ]; then
      printf '%s\n' "$row"
      return 0
    fi
    log "pid $pid left no graceful row; its log's last row: $(tail -n 1 "$candidate")"
    return 1
  done
  log "pid $pid left no per-PID log (looked under ${BASE_PATH:-$REPO_ROOT}/.masc/logs); graceful end unproven"
  return 2
}

# Wait for one old session to end and to have said why, gracefully. A
# session still alive at --timeout is left alone: no SIGKILL, and nothing
# new is started on top of it.
wait_for_graceful_exit() {
  local pid="$1" waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if ! still_running "$pid"; then
      local row
      row="$(read_exit_row "$pid")"
      case $? in
        0) log "pid $pid ended gracefully: $row"; return 0 ;;
        *) return 1 ;;
      esac
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "pid $pid still running after ${TIMEOUT}s; left alone (no SIGKILL, nothing new started)"
  return 1
}

start_fresh() {
  local -a args=()
  [ -n "$BASE_PATH" ] && args+=(--base-path "$BASE_PATH")
  args+=("$@")

  if [ -t 0 ] && [ -t 1 ]; then
    # Foreground: hand the pane to the new session; keys and Ctrl-C go to it.
    log "starting fresh TUI in the foreground: $TUI_BINARY ${args[*]:-}"
    exec "$TUI_BINARY" "${args[@]}"
  else
    # Non-interactive: start detached and prove it came up. stdin comes from
    # /dev/null: a detached surface must not hold the caller's stdin open
    # (a script chain or CI harness waits for that pipe to close).
    log "starting fresh TUI detached: $TUI_BINARY ${args[*]:-}"
    nohup "$TUI_BINARY" "${args[@]}" </dev/null >/dev/null 2>&1 &
    local fresh_pid=$!
    sleep 2
    # still_running, not kill -0: a fresh surface that died in those two
    # seconds is this shell's own unreaped child, and a zombie answers
    # kill -0. Reporting "is up" for a corpse is the one lie this script
    # must not tell -- it is the whole point of the wait.
    if ! still_running "$fresh_pid"; then
      log "ERROR: fresh TUI pid $fresh_pid died immediately; check its per-PID log"
      return 2
    fi
    log "fresh TUI pid $fresh_pid is up"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Self-test: exercises discovery and the graceful proof against fixtures.
# Nothing here starts a real TUI, builds, or sends a signal to anything but
# a sleep this test owns.
# --------------------------------------------------------------------------
self_test() {
  # Not `local`: the EXIT trap below runs after this function returns, and a
  # local would be out of scope by then (unbound under `set -u`).
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/tui-restart-selftest.XXXXXX")" || return 1
  trap 'rm -rf "$fixture"' EXIT
  mkdir -p "$fixture/bin" "$fixture/.masc/logs"

  # A fake `ps` so find_surfaces reads a crafted process table. It must
  # answer exactly the two invocations the script makes, and refuse anything
  # else -- a shim that quietly answers a question the script never asks
  # stops being evidence about the script.
  cat >"$fixture/bin/ps" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "-axo" ] && [ "$2" = "pid=,stat=,comm=" ]; then
  cat "$FAKE_PS_TABLE"
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "stat=" ] && [ "$3" = "-p" ] && [ -n "${4:-}" ]; then
  # Real ps exits 1 when the pid is not in the table; so does this.
  awk -v p="$4" '$1 == p { print $2; hit = 1 } END { exit(hit ? 0 : 1) }' \
    "$FAKE_PS_TABLE"
  exit $?
fi
echo "self-test ps shim: unexpected invocation: $*" >&2
exit 90
SHIM
  chmod +x "$fixture/bin/ps"

  # The traps: 102/103 are the two surface spellings; 104 is a log reader
  # (`tail -f .../masc-tui-9.log`), 105 an editor on the source, 106 the
  # server, 107 the build. 108 is the same surface as 103 but reported by a
  # `ps` that gives the full path (macOS) -- it must still be found. 109 and
  # 110 carry a surface name but are defunct: they are corpses waiting to be
  # reaped, not surfaces, and signalling one would burn the whole timeout.
  # Only 102, 103 and 108 may be discovered.
  cat >"$fixture/ps-table" <<'TABLE'
  101 Ss bash
  102 S masc_tui.exe
  103 S masc-tui
  104 S tail
  105 S less
  106 Sl masc
  107 R dune
  108 S /usr/local/bin/masc-tui
  109 Z masc_tui.exe
  110 Z+ /usr/local/bin/masc-tui
TABLE

  local failures=0
  check() {
    if [ "$2" = "$3" ]; then
      log "ok: $1"
    else
      log "FAIL: $1 (got [$2], want [$3])"
      failures=$((failures + 1))
    fi
  }

  # The functions under test are already defined in this shell; point them at
  # the fixture and call them directly. `ps` is the only external they reach,
  # so the shim goes first on PATH and FAKE_PS_TABLE names its table.
  BASE_PATH="$fixture"
  REPO_ROOT="$fixture"
  TIMEOUT=1
  # Done before the shim goes on PATH, because this one needs the real `ps`:
  # a real corpse, to check that still_running is not fooled the way `kill
  # -0` is. If this shell reaped the child before we could look, there is no
  # corpse to ask about and the check is skipped rather than passed -- a
  # check that cannot reach its subject must not report success.
  sleep 0 &
  local corpse=$! corpse_state
  sleep 1
  corpse_state="$(ps -o stat= -p "$corpse" 2>/dev/null | tr -d ' ' | cut -c1)"
  if [ "$corpse_state" = "Z" ]; then
    if still_running "$corpse"; then
      check "a real defunct child does not read as running" "running" "ended"
    else
      check "a real defunct child does not read as running" "ended" "ended"
    fi
  else
    log "skip: the shell reaped the corpse before it could be asked about" \
        "(stat [${corpse_state:-none}]); the table cases below still run"
  fi
  wait "$corpse" 2>/dev/null

  # Exported: the shim is a child process and reads this from its environment.
  export FAKE_PS_TABLE="$fixture/ps-table"
  PATH="$fixture/bin:$PATH"

  local found
  found="$(find_surfaces | tr '\n' ' ' | sed 's/ $//')"
  check "discovery finds the surfaces, path or bare" "$found" "102 103 108"

  # The state column drives the skip, so ask it directly too: if this ever
  # answers "no" for 109, the line above would go on passing while a corpse
  # slipped back into discovery through some other difference in the row.
  if is_zombie 109; then
    check "a defunct surface reads as defunct" "defunct" "defunct"
  else
    check "a defunct surface reads as defunct" "live" "defunct"
  fi
  if is_zombie 102; then
    check "a live surface does not read as defunct" "defunct" "live"
  else
    check "a live surface does not read as defunct" "live" "live"
  fi

  local row rc
  printf '[boot lines would be here]\n[masc-tui] exit: normal (signal SIGTERM)\n' \
    >"$fixture/.masc/logs/masc-tui-501.log"
  row="$(read_exit_row 501)"
  rc=$?
  check "a graceful row is proven (exit 0)" "$rc" "0"
  check "the row itself is echoed" "$row" "[masc-tui] exit: normal (signal SIGTERM)"

  printf '[masc-tui] exit: abnormal (exception Failure("boom"))\n' \
    >"$fixture/.masc/logs/masc-tui-502.log"
  read_exit_row 502 >/dev/null 2>&1
  check "an abnormal row is refused" "$?" "1"

  read_exit_row 503 >/dev/null 2>&1
  check "a missing log fails unproven" "$?" "2"

  # A session that never ends is reported and left alive. `sleep` here is
  # the stand-in for a stubborn surface; the script's rule is that it never
  # escalates to SIGKILL, so the test cleans it up itself. `$!` is the pid
  # directly -- a command substitution would block until sleep finished and
  # hand back a pid that is already gone.
  sleep 30 &
  local stubborn=$!
  TIMEOUT=1
  wait_for_graceful_exit "$stubborn" >/dev/null 2>&1
  check "a session alive past --timeout fails the wait" "$?" "1"
  if kill -0 "$stubborn" 2>/dev/null; then
    check "the stubborn session was left alive" "alive" "alive"
  else
    check "the stubborn session was left alive" "dead" "alive"
  fi
  kill -KILL "$stubborn" 2>/dev/null # test cleanup only
  wait "$stubborn" 2>/dev/null       # reap it, so no "Killed" job notice leaks

  if [ "$failures" -eq 0 ]; then
    log "self-test: all checks passed"
    return 0
  fi
  log "self-test: $failures check(s) failed"
  return 1
}

if [ -n "${TUI_GRACEFUL_RESTART_SELF_TEST:-}" ]; then
  self_test
  exit $?
fi

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --build) DO_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --timeout)
      [ $# -ge 2 ] || { log "ERROR: --timeout needs a number"; exit 4; }
      case "$2" in
        ''|*[!0-9]*) log "ERROR: --timeout needs a whole number of seconds"; exit 4 ;;
      esac
      TIMEOUT="$2"
      shift
      ;;
    --base-path)
      [ $# -ge 2 ] || { log "ERROR: --base-path needs a path"; exit 4; }
      BASE_PATH="$2"
      shift
      ;;
    --) shift; break ;;
    -h|--help)
      sed -n '2,64p' "$SCRIPT_DIR/tui-graceful-restart.sh" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) log "ERROR: unknown argument: $1 (see --help)"; exit 4 ;;
  esac
  shift
done

for required in ps awk grep sleep nohup; do
  command -v "$required" >/dev/null 2>&1 ||
    { log "ERROR: required command unavailable: $required"; exit 78; }
done

# ---- Step 0: build first, so a broken tree never costs a live session ----
if [ "$DO_BUILD" -eq 1 ]; then
  command -v dune >/dev/null 2>&1 ||
    { log "ERROR: --build needs dune, which is not on PATH"; exit 78; }
  log "building $TUI_BINARY"
  if ! (cd "$REPO_ROOT" && dune build bin/masc_tui.exe); then
    log "ERROR: build failed; the running session was left untouched"
    exit 3
  fi
fi

# ---- Step 1: find the running surface(s) ----
# No mapfile: macOS still ships bash 3.2, and this runs there first.
OLD_PIDS=()
while IFS= read -r pid; do
  [ -n "$pid" ] && OLD_PIDS+=("$pid")
done < <(find_surfaces)

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "${#OLD_PIDS[@]}" -gt 0 ]; then
    log "dry run: would signal pid(s): ${OLD_PIDS[*]}, then start $TUI_BINARY${BASE_PATH:+ --base-path $BASE_PATH}"
  else
    log "dry run: no running surface found; would just start $TUI_BINARY${BASE_PATH:+ --base-path $BASE_PATH}"
  fi
  exit 0
fi

# ---- Step 2: signal the old session(s), prove the end, start the new one ----
for pid in "${OLD_PIDS[@]}"; do
  log "sending SIGTERM to pid $pid"
  kill -TERM "$pid" 2>/dev/null || true
done

for pid in "${OLD_PIDS[@]}"; do
  wait_for_graceful_exit "$pid" || exit 1
done

start_fresh
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
log "restart complete"
exit 0
