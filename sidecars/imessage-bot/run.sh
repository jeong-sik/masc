#!/usr/bin/env bash
# iMessage Gate Bot runner.
#
# Mirrors discord-bot/run.sh: resolves MASC_BASE_PATH from the enclosing git
# repo root when unset, optionally loads .env, and tees combined stdout+stderr
# to a dated log file under $MASC_BASE_PATH/.masc/logs/.
#
# Unlike Discord, iMessage has no auth token — instead it needs Full Disk
# Access for the terminal so it can read ~/Library/Messages/chat.db.
#
# Usage:
#   ./run.sh              start the bot (foreground, tees to today's log)
#   ./run.sh tail         tail -F today's log file
#   ./run.sh status       pretty-print the current status.json

set -euo pipefail

script_dir() { cd "$(dirname "$0")" && pwd; }

resolve_base_path() {
  if [[ -n "${MASC_BASE_PATH:-}" ]]; then
    printf '%s\n' "$MASC_BASE_PATH"
    return
  fi
  git -C "$(script_dir)" rev-parse --show-toplevel
}

BASE_PATH="$(resolve_base_path)"
export MASC_BASE_PATH="$BASE_PATH"

LOG_DIR="$BASE_PATH/.masc/logs"
LOG_FILE="$LOG_DIR/imessage-sidecar-$(date +%Y%m%d).log"
STATUS_FILE="$BASE_PATH/.gate/runtime/imessage/status.json"
CHAT_DB="${HOME}/Library/Messages/chat.db"

cmd="${1:-start}"
case "$cmd" in
  start)
    cd "$(script_dir)"
    if [[ ! -r "$CHAT_DB" ]]; then
      echo "WARN: cannot read $CHAT_DB" >&2
      echo "      Grant Full Disk Access to your terminal:" >&2
      echo "      System Settings → Privacy & Security → Full Disk Access." >&2
    fi
    if [[ ! -f .env ]]; then
      echo "INFO: no .env found — running with defaults (gate=loopback, reply_mode=self-chat)." >&2
    fi
    mkdir -p "$LOG_DIR"
    printf 'Starting iMessage sidecar\n  MASC_BASE_PATH=%s\n  log file:      %s\n' \
      "$BASE_PATH" "$LOG_FILE" >&2
    python -m src 2>&1 | tee -a "$LOG_FILE"
    ;;
  tail)
    if [[ ! -f "$LOG_FILE" ]]; then
      echo "No log file yet at $LOG_FILE" >&2
      echo "Run './run.sh start' first, or check $LOG_DIR for older logs." >&2
      exit 1
    fi
    tail -F "$LOG_FILE"
    ;;
  status)
    if [[ ! -f "$STATUS_FILE" ]]; then
      echo "No status.json at $STATUS_FILE" >&2
      echo "The sidecar hasn't started yet or MASC_BASE_PATH points somewhere else." >&2
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      jq . "$STATUS_FILE"
    else
      cat "$STATUS_FILE"
    fi
    ;;
  stop)
    # Match by absolute script_dir path so we never hit another sidecar.
    if pgrep -f "$(script_dir)/src" >/dev/null 2>&1; then
      pkill -TERM -f "$(script_dir)/src"
      echo "Sent SIGTERM to imessage-bot processes." >&2
    else
      echo "imessage-bot not running." >&2
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop|tail|status]" >&2
    exit 2
    ;;
esac
