#!/usr/bin/env bash
# scripts/start-masc-supervised.sh
# Process-level supervisor for masc-mcp.
#
# Wraps start-masc-mcp.sh with auto-restart and a crash-loop circuit
# breaker.  Satisfies the operator durability requirement described in
# issue #10828 while respecting the <launchd> policy from ~/me/CLAUDE.md
# (script-based, no system-level daemon registration).
#
# Usage:
#   scripts/start-masc-supervised.sh [args forwarded to start-masc-mcp.sh]
#
# Environment knobs:
#   MASC_SUPERVISOR_LOG             — log file path
#                                     (default: <repo-root>/logs/masc-supervisor.log)
#   MASC_RESTART_WINDOW_SEC         — sliding window width for crash-loop
#                                     detection in seconds (default: 300)
#   MASC_MAX_RESTARTS_IN_WINDOW     — max exits allowed inside the window
#                                     before the supervisor aborts (default: 5)
#   MASC_RESTART_COOLDOWN_SEC       — sleep between restart attempts
#                                     (default: 5)
#
# Crash-loop detection:
#   When the server exits at least MASC_MAX_RESTARTS_IN_WINDOW times
#   within a rolling MASC_RESTART_WINDOW_SEC window the supervisor stops
#   restarting and exits with status 1 so that an outer watchdog (or the
#   operator) can investigate the root cause.  This prevents a tight
#   restart loop from masking an unrecovered crash (e.g. fd-leak, OOM).
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

WINDOW_SEC="${MASC_RESTART_WINDOW_SEC:-300}"
MAX_RESTARTS="${MASC_MAX_RESTARTS_IN_WINDOW:-5}"
COOLDOWN_SEC="${MASC_RESTART_COOLDOWN_SEC:-5}"

log() {
  printf '[%s][supervisor] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    | tee -a "$LOG_FILE" >&2
}

log "process supervisor starting (window=${WINDOW_SEC}s max_restarts=${MAX_RESTARTS} cooldown=${COOLDOWN_SEC}s)"
log "wrapping: $REPO_ROOT/start-masc-mcp.sh${*:+ $*}"

if [ ! -x "$REPO_ROOT/start-masc-mcp.sh" ]; then
  log "ERROR: start-masc-mcp.sh not found or not executable at $REPO_ROOT/start-masc-mcp.sh"
  exit 1
fi

# restart_timestamps holds the Unix epoch seconds of each recent exit,
# trimmed to the current sliding window on every iteration.
restart_timestamps=()

while true; do
  log "starting masc-mcp"
  start_epoch=$(date +%s)

  "$REPO_ROOT/start-masc-mcp.sh" "$@" || true
  exit_code=$?
  end_epoch=$(date +%s)
  uptime_s=$((end_epoch - start_epoch))

  log "masc-mcp exited code=$exit_code uptime=${uptime_s}s"

  # Trim restart_timestamps to the sliding window.
  cutoff=$((end_epoch - WINDOW_SEC))
  fresh=()
  for ts in "${restart_timestamps[@]+"${restart_timestamps[@]}"}"; do
    if [[ "$ts" -gt "$cutoff" ]]; then
      fresh+=("$ts")
    fi
  done
  restart_timestamps=("${fresh[@]+"${fresh[@]}"}")

  # Record this exit in the window.
  restart_timestamps+=("$end_epoch")
  window_count=${#restart_timestamps[@]}

  if [[ "$window_count" -ge "$MAX_RESTARTS" ]]; then
    log "ABORT: $window_count exits in ${WINDOW_SEC}s window (limit $MAX_RESTARTS) — not restarting"
    log "Investigate root cause then restart manually with: $REPO_ROOT/start-masc-mcp.sh $*"
    exit 1
  fi

  log "restart in ${COOLDOWN_SEC}s (exit #${window_count} in ${WINDOW_SEC}s window)"
  sleep "$COOLDOWN_SEC"
done
