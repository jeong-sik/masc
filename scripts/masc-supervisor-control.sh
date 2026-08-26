#!/usr/bin/env bash
# Start, inspect, and stop the local MASC process supervisor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/start-masc-supervised.sh"
HOST="${MASC_HOST:-127.0.0.1}"
PORT="${MASC_PORT:-8935}"
STOP_TIMEOUT_SEC="${MASC_SUPERVISOR_STOP_TIMEOUT_SEC:-180}"

usage() {
  cat >&2 <<'EOF'
Usage: MASC_BASE_PATH=<workspace> scripts/masc-supervisor-control.sh <start|status|stop>

Commands:
  start   Start the process supervisor in the background.
  status  Check the supervisor PID, its listener child, and /health.
  stop    Send TERM to the supervisor and wait for its child to shut down.

Environment:
  MASC_BASE_PATH                    Required workspace BasePath.
  MASC_HOST                         Listener host. Defaults to 127.0.0.1.
  MASC_PORT                         Listener port. Defaults to 8935.
  MASC_KEEPER_BOOTSTRAP_ENABLED     Defaults to true for this operator path.
  MASC_SUPERVISOR_PID_FILE          Defaults below <base>/.masc/logs.
  MASC_SUPERVISOR_LOG               Supervisor event log path.
  MASC_SUPERVISOR_OUTPUT_LOG        Combined stdout/stderr path.
  MASC_SUPERVISOR_STOP_TIMEOUT_SEC  Graceful stop timeout. Defaults to 180.
EOF
}

die() {
  echo "[masc-supervisor-control] error: $*" >&2
  exit 1
}

require_base_path() {
  BASE_PATH="${MASC_BASE_PATH:-}"
  [ -n "$BASE_PATH" ] || die "MASC_BASE_PATH is required"
  [ -d "$BASE_PATH" ] || die "MASC_BASE_PATH is not a directory: $BASE_PATH"

  LOG_DIR="$BASE_PATH/.masc/logs"
  PID_FILE="${MASC_SUPERVISOR_PID_FILE:-$LOG_DIR/masc-supervisor-$PORT.pid}"
  EVENT_LOG="${MASC_SUPERVISOR_LOG:-$LOG_DIR/masc-supervisor-$PORT.log}"
  OUTPUT_LOG="${MASC_SUPERVISOR_OUTPUT_LOG:-$LOG_DIR/masc-$PORT-supervised.out.log}"
}

read_pid() {
  [ -f "$PID_FILE" ] || return 1
  IFS= read -r supervisor_pid <"$PID_FILE" || return 1
  case "$supervisor_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$supervisor_pid"
}

is_supervisor_pid() {
  local pid="$1"
  local command_line

  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *"$SUPERVISOR"*) return 0 ;;
    *) return 1 ;;
  esac
}

listener_pid() {
  lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

cmd_start() {
  local pid existing_pid temp_pid_file

  [ -x "$SUPERVISOR" ] || die "supervisor is missing or not executable: $SUPERVISOR"
  mkdir -p "$LOG_DIR" "$(dirname "$PID_FILE")"

  if existing_pid="$(read_pid 2>/dev/null)" && is_supervisor_pid "$existing_pid"; then
    die "supervisor is already running: pid=$existing_pid"
  fi
  if [ -f "$PID_FILE" ]; then
    echo "[masc-supervisor-control] removing stale PID file: $PID_FILE" >&2
    rm -f "$PID_FILE"
  fi

  if [ -n "$(listener_pid)" ]; then
    die "port $PORT already has a listener; refusing a second server"
  fi

  umask 077
  nohup env \
    MASC_KEEPER_BOOTSTRAP_ENABLED="${MASC_KEEPER_BOOTSTRAP_ENABLED:-true}" \
    MASC_SUPERVISOR_LOG="$EVENT_LOG" \
    "$SUPERVISOR" \
      --http --host "$HOST" --port "$PORT" --base-path "$BASE_PATH" \
      >>"$OUTPUT_LOG" 2>&1 &
  pid=$!

  temp_pid_file="$PID_FILE.tmp.$$"
  printf '%s\n' "$pid" >"$temp_pid_file"
  mv -f "$temp_pid_file" "$PID_FILE"

  sleep 1
  if ! is_supervisor_pid "$pid"; then
    rm -f "$PID_FILE"
    die "supervisor exited during startup; inspect $OUTPUT_LOG"
  fi

  echo "[masc-supervisor-control] started supervisor pid=$pid port=$PORT"
  echo "[masc-supervisor-control] status: MASC_BASE_PATH=$BASE_PATH $0 status"
}

cmd_status() {
  local pid child_pid child_parent

  pid="$(read_pid 2>/dev/null)" || die "supervisor PID file is missing or invalid: $PID_FILE"
  is_supervisor_pid "$pid" || die "PID file does not name a running MASC supervisor: pid=$pid"

  child_pid="$(listener_pid)"
  if [ -z "$child_pid" ]; then
    echo "[masc-supervisor-control] supervisor pid=$pid state=starting listener=none"
    return 2
  fi

  child_parent="$(ps -p "$child_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)"
  [ "$child_parent" = "$pid" ] \
    || die "port $PORT listener pid=$child_pid is not owned by supervisor pid=$pid"

  if curl -fsS --max-time 2 --url "http://$HOST:$PORT/health" >/dev/null; then
    echo "[masc-supervisor-control] supervisor pid=$pid child=$child_pid state=healthy port=$PORT"
  else
    die "supervisor child pid=$child_pid owns port $PORT but /health failed"
  fi
}

cmd_stop() {
  local pid waited_ticks max_ticks child_pid

  pid="$(read_pid 2>/dev/null)" || die "supervisor PID file is missing or invalid: $PID_FILE"
  is_supervisor_pid "$pid" || die "PID file does not name a running MASC supervisor: pid=$pid"
  case "$STOP_TIMEOUT_SEC" in
    ''|*[!0-9]*) die "MASC_SUPERVISOR_STOP_TIMEOUT_SEC must be a positive integer" ;;
  esac
  [ "$STOP_TIMEOUT_SEC" -ge 1 ] \
    || die "MASC_SUPERVISOR_STOP_TIMEOUT_SEC must be at least 1"

  echo "[masc-supervisor-control] stopping supervisor pid=$pid" >&2
  kill -TERM "$pid"
  waited_ticks=0
  max_ticks=$((STOP_TIMEOUT_SEC * 2))
  while kill -0 "$pid" 2>/dev/null && [ "$waited_ticks" -lt "$max_ticks" ]; do
    sleep 0.5
    waited_ticks=$((waited_ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    die "supervisor did not stop within ${STOP_TIMEOUT_SEC}s; no force kill was sent"
  fi

  rm -f "$PID_FILE"
  child_pid="$(listener_pid)"
  [ -z "$child_pid" ] \
    || die "supervisor stopped but port $PORT is still owned by pid=$child_pid"
  echo "[masc-supervisor-control] stopped"
}

case "${1:-}" in
  start)
    shift
    [ "$#" -eq 0 ] || die "start does not accept arguments; use the documented environment variables"
    require_base_path
    cmd_start
    ;;
  status)
    shift
    [ "$#" -eq 0 ] || die "status does not accept arguments"
    require_base_path
    cmd_status
    ;;
  stop)
    shift
    [ "$#" -eq 0 ] || die "stop does not accept arguments"
    require_base_path
    cmd_stop
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage
    die "unknown command: $1"
    ;;
esac
