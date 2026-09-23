#!/usr/bin/env bash
# scripts/test-tui-graceful-restart-e2e.sh
#
# One real cycle of scripts/tui-graceful-restart.sh, end to end: a live
# process is discovered by its comm, SIGTERMed, its per-PID log is read for
# the graceful row, and a fresh instance is started and found alive. The
# self-test inside that script covers the pieces in isolation; this drives the
# whole script as a subprocess against real processes and real signals.
#
# It then runs the same cycle a second time against a mutated copy of the
# script with the SIGTERM removed, and requires the checks to fail. A guard
# that cannot fail is a decoration, and the only way to know this one bites is
# to break the thing it watches and watch it bite.
#
# The surface is a stand-in, not the OCaml TUI: this lane has no OCaml
# toolchain, so the binary is a copy of bash named `masc_tui.exe`. comm is the
# executable's basename, so discovery sees the real name. A BASH_ENV script
# makes that copy trap SIGTERM and write the exact row the real TUI writes --
# `[masc-tui] exit: normal (signal SIGTERM)`, the vocabulary owned by
# bin/masc_tui_exit_reason.ml. So what this proves is the restart script's own
# path: discovery, the signal, the row read, the fresh start. That the real
# TUI writes that row is #37949's own test, not this one's claim.
#
# Usage: scripts/test-tui-graceful-restart-e2e.sh
# Exit:  0 all checks passed, 1 a check failed, 2 refused to run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR/tui-graceful-restart.sh"
[ -f "$REAL_SCRIPT" ] || { echo "missing $REAL_SCRIPT" >&2; exit 2; }

GRACEFUL_ROW='[masc-tui] exit: normal (signal SIGTERM)'

# Defunct processes are skipped for the same reason the script under test
# skips them: a zombie keeps its comm and answers kill -0, but it is a corpse
# waiting to be reaped, not a surface. Without this the refusal below latches
# on forever -- one crashed stand-in under ppid 1 was enough to make this
# test refuse to run at all, which is how the script's own version of this
# bug was found.
surface_pids() {
  ps -axo pid=,stat=,comm= 2>/dev/null |
    awk '{ n = $3; sub(/^.*\//, "", n)
           if (substr($2, 1, 1) != "Z" && (n == "masc_tui.exe" || n == "masc-tui"))
             print $1 }'
}

kill_surfaces() {
  local p
  for p in $(surface_pids); do
    kill -KILL "$p" 2>/dev/null
    # Reap it when it is ours, so no "Killed" job notice leaks into the
    # output. `wait` on a pid that is not our child just fails, quietly.
    wait "$p" 2>/dev/null
  done
  sleep 1
}

# Refuse rather than restart someone's live TUI. The script under test finds
# surfaces machine-wide by comm, so if a real one is already up this test
# would SIGTERM it and start the stand-in in its place.
pre_existing="$(surface_pids)"
if [ -n "$pre_existing" ]; then
  echo "[e2e] refusing: a TUI surface is already running (pid(s):" \
       "$(echo "$pre_existing" | tr '\n' ' ')). This test restarts every" \
       "surface it finds. Quit the TUI and run it again." >&2
  exit 2
fi

failures=0
check() {
  if [ "$2" = "$3" ]; then
    printf '[e2e] ok: %s\n' "$1"
  else
    printf '[e2e] FAIL: %s (got [%s], want [%s])\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

workdirs=()
cleanup() {
  kill_surfaces
  local d
  for d in ${workdirs+"${workdirs[@]}"}; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# A temp repo layout so the copied script derives REPO_ROOT=$tmp and
# TUI_BINARY=$tmp/_build/default/bin/masc_tui.exe, and keeps its logs under
# $tmp/.masc/logs. Nothing touches the real checkout.
#
# $1 = "intact" or "no-sigterm" (the mutation). Echoes the layout path.
build_layout() {
  local mode="$1" t
  t="$(mktemp -d "${TMPDIR:-/tmp}/tui-restart-e2e.XXXXXX")" || return 1
  mkdir -p "$t/scripts" "$t/_build/default/bin" "$t/.masc/logs"

  if [ "$mode" = "no-sigterm" ]; then
    sed 's|kill -TERM |: mutation-no-sigterm |' "$REAL_SCRIPT" \
      >"$t/scripts/tui-graceful-restart.sh"
  else
    cp "$REAL_SCRIPT" "$t/scripts/tui-graceful-restart.sh"
  fi

  cp "$(command -v bash)" "$t/_build/default/bin/masc_tui.exe"
  chmod +x "$t/_build/default/bin/masc_tui.exe"

  # What the stand-in does when it starts: trap SIGTERM, write the real row,
  # exit. Two details that are easy to get wrong:
  #
  #   * The `case "$0"` guard. BASH_ENV is read by *every* non-interactive
  #     bash that inherits it -- including the restart script under test.
  #     Without the guard that script sources this file and blocks in `wait`
  #     instead of running its own body, and the cycle hangs with no output.
  #   * `sleep & wait` rather than a bare `sleep`. A bare final command is
  #     exec'd, which would make comm `sleep` and hide the surface from
  #     discovery; and `wait` lets the trap run the moment the signal lands
  #     instead of after a foreground sleep finishes.
  cat >"$t/standin.sh" <<'STANDIN'
case "$0" in
  */masc_tui.exe)
    trap 'printf "[masc-tui] exit: normal (signal SIGTERM)\n" \
            >> "$STANDIN_LOG_DIR/masc-tui-$$.log"; exit 0' TERM
    sleep 300 &
    wait $!
    ;;
esac
STANDIN

  printf '%s' "$t"
}

# Runs one cycle in its own layout. Sets: c_rc c_old c_row c_fresh c_echo
run_cycle() {
  local mode="$1" t
  t="$(build_layout "$mode")" || return 1
  workdirs+=("$t")

  export BASH_ENV="$t/standin.sh"
  export STANDIN_LOG_DIR="$t/.masc/logs"

  "$t/_build/default/bin/masc_tui.exe" </dev/null &
  local old=$!
  sleep 1
  c_comm="$(ps -o comm= -p "$old" 2>/dev/null | sed 's:.*/::;s/ *$//')"

  ( cd "$t" && bash "$t/scripts/tui-graceful-restart.sh" --timeout 5 ) \
    >"$t/cycle.out" 2>&1
  c_rc=$?

  if kill -0 "$old" 2>/dev/null; then c_old="alive"; else c_old="gone"; fi

  c_row=""
  [ -f "$t/.masc/logs/masc-tui-$old.log" ] &&
    c_row="$(grep -F "$GRACEFUL_ROW" "$t/.masc/logs/masc-tui-$old.log" | tail -n 1)"

  c_fresh="$(surface_pids | grep -vx "$old" | grep -c .)"

  if grep -qF "$GRACEFUL_ROW" "$t/cycle.out"; then c_echo="yes"; else c_echo="no"; fi

  c_out="$t/cycle.out"
  kill_surfaces
}

# ---------------------------------------------------------------- intact ---
echo "[e2e] --- cycle 1: the script as written ---"
run_cycle intact || { echo "[e2e] could not build the layout" >&2; exit 2; }
check "the stand-in surface is up under the real comm" "$c_comm" "masc_tui.exe"
check "the cycle exits 0" "$c_rc" "0"
check "the old session ended" "$c_old" "gone"
check "the old session left the graceful row" "$c_row" "$GRACEFUL_ROW"
check "exactly one fresh surface is up" "$c_fresh" "1"
check "the cycle echoed the row it read" "$c_echo" "yes"
[ "$c_rc" = "0" ] || { echo "--- cycle output ---" >&2; cat "$c_out" >&2; }

# ------------------------------------------------------- mutation control ---
# Same cycle, one line of the script removed. If these still look like a pass,
# the checks above are not watching anything.
echo "[e2e] --- cycle 2: mutation control, SIGTERM removed ---"
mutation_hits="$(sed -n 's|kill -TERM |&|p' "$REAL_SCRIPT" | grep -c .)"
check "the mutation has exactly one line to remove" "$mutation_hits" "1"

run_cycle no-sigterm || { echo "[e2e] could not build the layout" >&2; exit 2; }
check "the mutated cycle does not exit 0" \
  "$([ "$c_rc" != "0" ] && echo differs || echo zero)" "differs"
check "the mutated cycle leaves the old session alive" "$c_old" "alive"
check "the mutated cycle proves no graceful row" "$c_row" ""
check "the mutated cycle starts no fresh surface" "$c_fresh" "0"

if [ "$failures" -eq 0 ]; then
  printf '[e2e] all checks passed\n'
  exit 0
fi
printf '[e2e] %s check(s) failed\n' "$failures"
exit 1
