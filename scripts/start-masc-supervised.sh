#!/usr/bin/env bash
# scripts/start-masc-supervised.sh
# Process-level supervisor for masc.
#
# Wraps start-masc.sh with continuous auto-restart.  Satisfies the
# operator durability requirement described in issue #10828 while
# respecting the <launchd> policy from ~/me/CLAUDE.md (script-based,
# no system-level daemon registration).
#
# Usage:
#   scripts/start-masc-supervised.sh [args forwarded to start-masc.sh]
#
# Environment knobs:
#   MASC_SUPERVISOR_LOG             — log file path
#                                     (default: <repo-root>/logs/masc-supervisor.log)
#   MASC_RESTART_COOLDOWN_SEC       — sleep between restart attempts
#                                     (default: 5)
#
# Restart contract:
#   Every child exit is logged with its real exit status and uptime.
#   Child failures never revoke the supervisor's restart responsibility.
#   TERM, INT, and HUP remain explicit external stop signals: they are
#   forwarded to the active child and terminate the supervisor.
#
# Relationship to lib/supervisor.ml:
#   lib/supervisor.ml manages *Eio fibers* inside a single OS process.
#   This script manages the *OS process* itself.  The two layers are
#   orthogonal.  See lib/supervisor.mli §"Scope of protection" for the
#   full boundary definition.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="${MASC_SUPERVISOR_LOG:-$REPO_ROOT/logs/masc-supervisor.log}"
mkdir -p "$(dirname "$LOG_FILE")"

COOLDOWN_SEC="${MASC_RESTART_COOLDOWN_SEC:-5}"
active_pid=""
active_kind=""
stop_signal=""
stop_exit_code=0
stop_forwarded_pid=""

log() {
  printf '[%s][supervisor] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    | tee -a "$LOG_FILE" >&2
}

forward_stop_to_active() {
  if [ -n "$stop_signal" ] \
    && [ -n "$active_pid" ] \
    && [ "$stop_forwarded_pid" != "$active_pid" ] \
    && kill -0 "$active_pid" 2>/dev/null
  then
    log "forwarding SIG${stop_signal} to ${active_kind} pid=${active_pid}"
    kill "-${stop_signal}" "$active_pid" 2>/dev/null || true
    stop_forwarded_pid="$active_pid"
  fi
}

request_stop() {
  local signal_name="$1"
  local signal_number

  if [ -n "$stop_signal" ]; then
    return
  fi

  signal_number=$(kill -l "$signal_name")
  stop_signal="$signal_name"
  stop_exit_code=$((128 + signal_number))
  log "supervisor received SIG${signal_name}; stop requested"

  forward_stop_to_active
}

run_active() {
  local kind="$1"
  local status
  local reaped_status
  shift

  active_kind="$kind"
  "$@" &
  active_pid=$!
  stop_forwarded_pid=""
  forward_stop_to_active
  wait "$active_pid"
  status=$?

  if [ -n "$stop_signal" ]; then
    wait "$active_pid" 2>/dev/null
    reaped_status=$?
    if [ "$reaped_status" -ne 127 ]; then
      status="$reaped_status"
    fi
  fi

  active_pid=""
  active_kind=""
  stop_forwarded_pid=""
  return "$status"
}

stop_if_requested() {
  if [ -n "$stop_signal" ]; then
    log "process supervisor stopping after SIG${stop_signal}"
    exit "$stop_exit_code"
  fi
}

trap 'request_stop TERM' TERM
trap 'request_stop INT' INT
trap 'request_stop HUP' HUP

log "process supervisor starting (cooldown=${COOLDOWN_SEC}s)"
log "wrapping: $REPO_ROOT/start-masc.sh${*:+ $*}"

if [ ! -x "$REPO_ROOT/start-masc.sh" ]; then
  log "ERROR: start-masc.sh not found or not executable at $REPO_ROOT/start-masc.sh"
  exit 1
fi

while true; do
  stop_if_requested
  log "starting masc"
  start_epoch=$(date +%s)

  # No `set -e` is active, so a failing start-masc.sh does not abort this
  # loop; `|| true` here would make `$?` observe `true` and record every
  # exit — including SIGSEGV (139) and SIGTERM (143) — as code=0.
  run_active "masc" "$REPO_ROOT/start-masc.sh" "$@"
  exit_code=$?
  end_epoch=$(date +%s)
  uptime_s=$((end_epoch - start_epoch))

  exit_detail=""
  if [ "$exit_code" -gt 128 ]; then
    signal_name=$(kill -l $((exit_code - 128)) 2>/dev/null || true)
    if [ -n "$signal_name" ]; then
      exit_detail=" signal=SIG${signal_name}"
    fi
  fi

  log "masc exited code=${exit_code}${exit_detail} uptime=${uptime_s}s"
  stop_if_requested

  log "restart in ${COOLDOWN_SEC}s"
  run_active "restart cooldown" sleep "$COOLDOWN_SEC"
  stop_if_requested
done
