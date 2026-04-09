#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/trpg-prune-loop.sh <command> [options]

Commands:
  once                Run one prune pass immediately
  start               Start periodic prune loop in tmux
  stop                Stop periodic prune loop tmux session
  status              Show loop status and recent log lines

Options:
  --session <name>       tmux session name (default: masc-trpg-prune)
  --interval-sec <n>     loop interval seconds for start (default: 300)
  --room-id <id>         TRPG room id (default: default)
  --base-path <path>     Base path containing trpg/events.sqlite3 (default: $MASC_BASE_PATH or $HOME/me)
  --keep-sessions <n>    Keep last N room.created sessions (default: 1)
  --vacuum               Run VACUUM on each prune pass
  --help                 Show this help

Examples:
  scripts/trpg-prune-loop.sh once --room-id default --keep-sessions 1
  scripts/trpg-prune-loop.sh start --interval-sec 600
  scripts/trpg-prune-loop.sh status
  scripts/trpg-prune-loop.sh stop
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PRUNE_SCRIPT="$SCRIPT_DIR/trpg-room-prune.sh"

COMMAND="${1:-status}"
if [[ $# -gt 0 ]]; then
  shift
fi

SESSION_NAME="masc-trpg-prune"
INTERVAL_SEC=300
ROOM_ID="default"
BASE_PATH="${MASC_BASE_PATH:-${HOME}/me}"
KEEP_SESSIONS=1
VACUUM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION_NAME="${2:-}"
      shift 2
      ;;
    --interval-sec)
      INTERVAL_SEC="${2:-}"
      shift 2
      ;;
    --room-id)
      ROOM_ID="${2:-}"
      shift 2
      ;;
    --base-path)
      BASE_PATH="${2:-}"
      shift 2
      ;;
    --keep-sessions)
      KEEP_SESSIONS="${2:-}"
      shift 2
      ;;
    --vacuum)
      VACUUM=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SESSION_NAME" ]]; then
  echo "ERROR: --session cannot be empty" >&2
  exit 1
fi

if ! [[ "$INTERVAL_SEC" =~ ^[0-9]+$ ]] || [[ "$INTERVAL_SEC" -lt 1 ]]; then
  echo "ERROR: --interval-sec must be a positive integer" >&2
  exit 1
fi

if ! [[ "$KEEP_SESSIONS" =~ ^[0-9]+$ ]] || [[ "$KEEP_SESSIONS" -lt 1 ]]; then
  echo "ERROR: --keep-sessions must be a positive integer" >&2
  exit 1
fi

if [[ ! -x "$PRUNE_SCRIPT" ]]; then
  echo "ERROR: prune script not executable: $PRUNE_SCRIPT" >&2
  exit 1
fi

run_once() {
  local -a args=(
    --room-id "$ROOM_ID"
    --base-path "$BASE_PATH"
    --keep-sessions "$KEEP_SESSIONS"
    --apply
  )
  if [[ "$VACUUM" -eq 1 ]]; then
    args+=(--vacuum)
  fi
  "$PRUNE_SCRIPT" "${args[@]}"
}

require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is required for '$COMMAND'" >&2
    exit 1
  fi
}

loop_body() {
  while true; do
    echo "[trpg-prune-loop] $(date '+%Y-%m-%d %H:%M:%S') run_once"
    if ! run_once; then
      echo "[trpg-prune-loop] prune failed; retry after sleep"
    fi
    echo "[trpg-prune-loop] sleep ${INTERVAL_SEC}s"
    sleep "$INTERVAL_SEC"
  done
}

case "$COMMAND" in
  once)
    run_once
    ;;
  _loop)
    loop_body
    ;;
  start)
    require_tmux
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      echo "already running: tmux session '$SESSION_NAME'"
      exit 0
    fi
    loop_cmd="$(printf '%q ' "$SELF_PATH" _loop --session "$SESSION_NAME" --interval-sec "$INTERVAL_SEC" --room-id "$ROOM_ID" --base-path "$BASE_PATH" --keep-sessions "$KEEP_SESSIONS")"
    if [[ "$VACUUM" -eq 1 ]]; then
      loop_cmd+=$(printf '%q ' --vacuum)
    fi
    tmux new-session -d -s "$SESSION_NAME" "$loop_cmd"
    echo "started: tmux session '$SESSION_NAME' (interval=${INTERVAL_SEC}s, room_id=${ROOM_ID})"
    ;;
  stop)
    require_tmux
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      tmux kill-session -t "$SESSION_NAME"
      echo "stopped: tmux session '$SESSION_NAME'"
    else
      echo "not running: tmux session '$SESSION_NAME'"
    fi
    ;;
  status)
    require_tmux
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      echo "running: tmux session '$SESSION_NAME'"
      tmux capture-pane -pt "$SESSION_NAME" -S -20 || true
    else
      echo "stopped: tmux session '$SESSION_NAME'"
    fi
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
