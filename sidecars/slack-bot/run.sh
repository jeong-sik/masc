#!/usr/bin/env bash
# Slack Gate Bot runner.
#
# Mirrors discord-bot/run.sh. Slack uses Socket Mode and needs both a Bot
# Token (xoxb-) and an App-Level Token (xapp-). See README for the App
# manifest setup.
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
LOG_FILE="$LOG_DIR/slack-sidecar-$(date +%Y%m%d).log"
STATUS_FILE="$BASE_PATH/.gate/runtime/slack/status.json"

cmd="${1:-start}"
case "$cmd" in
  start)
    cd "$(script_dir)"
    if [[ ! -f .env ]]; then
      echo "ERROR: .env missing. Copy .env.example and fill SLACK_BOT_TOKEN + SLACK_APP_TOKEN." >&2
      exit 1
    fi
    mkdir -p "$LOG_DIR"
    printf 'Starting Slack sidecar\n  MASC_BASE_PATH=%s\n  log file:      %s\n' \
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
      echo "Sent SIGTERM to slack-bot processes." >&2
    else
      echo "slack-bot not running." >&2
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop|tail|status]" >&2
    exit 2
    ;;
esac
