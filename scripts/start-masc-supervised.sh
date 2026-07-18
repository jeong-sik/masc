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
#   MASC_RUNTIME_LKG_FILE           — health-verified artifact descriptor
#                                     (default: <repo-root>/logs/masc-runtime-lkg.v1)
#   MASC_SUPERVISOR_HEALTH_PROBE_SEC — observation cadence only; never a
#                                     readiness timeout (default: 1)
#
# Restart contract:
#   Every child exit is logged with its real exit status and uptime.
#   A PID-bound healthy runtime keeps continuous restart responsibility.
#   A startup that never publishes a candidate or never reaches PID-bound
#   health is terminal, so deterministic startup failures are not amplified.
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
HEALTH_PROBE_SEC="${MASC_SUPERVISOR_HEALTH_PROBE_SEC:-1}"
ARTIFACT_CONTRACT="${MASC_RUNTIME_ARTIFACT_CONTRACT:-$REPO_ROOT/scripts/lib/runtime-artifact-contract.sh}"
LKG_FILE="${MASC_RUNTIME_LKG_FILE:-$REPO_ROOT/logs/masc-runtime-lkg.v1}"
ATTEMPT_DIR="$(dirname "$LKG_FILE")"
CANDIDATE_FILE="$ATTEMPT_DIR/masc-runtime-candidate.$$.v1"
PROOF_FILE="$ATTEMPT_DIR/masc-runtime-health-proof.$$.v1"
HEALTH_PROOF_SCHEMA="masc.runtime_health_proof.v1"
active_pid=""
active_kind=""
monitor_pid=""
completed_pid=""
stop_signal=""
stop_exit_code=0
stop_forwarded_pid=""

log() {
  printf '[%s][supervisor] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    | tee -a "$LOG_FILE" >&2
}

if [ ! -r "$ARTIFACT_CONTRACT" ]; then
  log "ERROR: runtime artifact contract unavailable: $ARTIFACT_CONTRACT"
  exit 78
fi
case "$HEALTH_PROBE_SEC" in
  ''|*[!0-9]*)
    log "ERROR: MASC_SUPERVISOR_HEALTH_PROBE_SEC must be a positive integer"
    exit 78
    ;;
esac
if [ "$HEALTH_PROBE_SEC" -lt 1 ]; then
  log "ERROR: MASC_SUPERVISOR_HEALTH_PROBE_SEC must be at least 1"
  exit 78
fi
for required_command in lsof curl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    log "ERROR: required runtime health-proof command unavailable: $required_command"
    exit 78
  fi
done
# shellcheck source=/dev/null
source "$ARTIFACT_CONTRACT"
mkdir -p "$ATTEMPT_DIR"

write_health_proof() {
  local child_pid="$1"
  local artifact_hash="$2"
  local temp="$PROOF_FILE.tmp.$$"

  case "$child_pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  masc_runtime_artifact_valid_hash "$artifact_hash" || return 2

  umask 077
  if ! printf '%s\n%s\n%s\n' \
      "$HEALTH_PROOF_SCHEMA" "$child_pid" "$artifact_hash" >"$temp"
  then
    rm -f "$temp"
    return 1
  fi
  chmod 600 "$temp" || {
    rm -f "$temp"
    return 1
  }
  mv -f "$temp" "$PROOF_FILE"
}

verify_health_proof() {
  local expected_pid="$1"
  local schema proof_pid proof_hash

  [ -f "$PROOF_FILE" ] || return 1
  {
    IFS= read -r schema || return 1
    IFS= read -r proof_pid || return 1
    IFS= read -r proof_hash || return 1
    if IFS= read -r _; then
      return 1
    fi
  } <"$PROOF_FILE"

  [ "$schema" = "$HEALTH_PROOF_SCHEMA" ] || return 1
  [ "$proof_pid" = "$expected_pid" ] || return 1
  masc_runtime_artifact_valid_hash "$proof_hash" || return 1
  masc_runtime_artifact_descriptor_read "$CANDIDATE_FILE" || return 1
  [ "$proof_hash" = "$MASC_ARTIFACT_SHA256" ]
}

monitor_runtime_candidate() {
  local child_pid="$1"
  local listener_pid=""
  local actual_hash=""

  while kill -0 "$child_pid" 2>/dev/null; do
    if masc_runtime_artifact_descriptor_read "$CANDIDATE_FILE"; then
      listener_pid="$(lsof -ti "tcp:$MASC_ARTIFACT_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
      if [ "$listener_pid" = "$child_pid" ] \
        && curl -fsS --max-time 1 \
          "http://127.0.0.1:$MASC_ARTIFACT_PORT/health" >/dev/null 2>&1
      then
        actual_hash="$(masc_runtime_artifact_hash "$MASC_ARTIFACT_PATH")" || return
        if [ "$actual_hash" != "$MASC_ARTIFACT_SHA256" ]; then
          log "ERROR: healthy listener artifact changed before LKG promotion"
          return
        fi
        if masc_runtime_artifact_promote "$CANDIDATE_FILE" "$LKG_FILE" "$REPO_ROOT"; then
          if write_health_proof "$child_pid" "$actual_hash"; then
            log "health-verified runtime artifact promoted sha256=$actual_hash pid=$child_pid"
          else
            log "ERROR: healthy runtime artifact promotion lacked an exact health proof"
          fi
        else
          log "ERROR: healthy runtime artifact failed exact LKG promotion"
        fi
        return
      fi
    fi
    sleep "$HEALTH_PROBE_SEC"
  done
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
  monitor_pid=""
  if [ "$kind" = "masc" ]; then
    monitor_runtime_candidate "$active_pid" &
    monitor_pid=$!
  fi
  forward_stop_to_active
  wait "$active_pid"
  status=$?

  if [ -n "$monitor_pid" ]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=""
  fi

  if [ -n "$stop_signal" ]; then
    wait "$active_pid" 2>/dev/null
    reaped_status=$?
    if [ "$reaped_status" -ne 127 ]; then
      status="$reaped_status"
    fi
  fi

  completed_pid="$active_pid"
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
  rm -f "$CANDIDATE_FILE" "$PROOF_FILE"
  log "starting masc"
  start_epoch=$(date +%s)

  # No `set -e` is active, so a failing start-masc.sh does not abort this
  # loop; `|| true` here would make `$?` observe `true` and record every
  # exit — including SIGSEGV (139) and SIGTERM (143) — as code=0.
  run_active "masc" env \
    MASC_RUNTIME_ARTIFACT_CONTRACT="$ARTIFACT_CONTRACT" \
    MASC_RUNTIME_LKG_FILE="$LKG_FILE" \
    MASC_RUNTIME_CANDIDATE_FILE="$CANDIDATE_FILE" \
    MASC_ENABLE_VERIFIED_LKG_FALLBACK=1 \
    "$REPO_ROOT/start-masc.sh" "$@"
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

  if [ ! -f "$CANDIDATE_FILE" ]; then
    log "terminal startup state: no runtime candidate was published; refusing restart amplification"
    exit "$exit_code"
  fi
  if ! verify_health_proof "$completed_pid"; then
    log "terminal startup state: runtime candidate lacks an exact PID-bound health proof; refusing restart amplification"
    exit "$exit_code"
  fi

  log "restart in ${COOLDOWN_SEC}s"
  run_active "restart cooldown" sleep "$COOLDOWN_SEC"
  stop_if_requested
done
