#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_PATH_OVERRIDE=""
DATE_OVERRIDE=""
TAIL_LINES=40
MIN_LEVEL="DEBUG"
MODULE_FILTER=""
MESSAGE_FILTER=""
FOLLOW_MODE=1
RAW_MODE=0

usage() {
  cat <<'EOF'
Usage: scripts/logs-follow.sh [options]

Follow MASC structured server logs from <base-path>/.masc/logs/system_log_YYYY-MM-DD.jsonl.
If you pass a repo or worktree path, the script resolves it to the owning repo root automatically.

Options:
  --base-path <path>    Override MASC base path (default: MASC_BASE_PATH or HOME)
  --date <YYYY-MM-DD>   Read a specific log file instead of today's rotating file
  --lines <n>           Tail last N lines before following (default: 40, use 0 for only new lines)
  --level <level>       Minimum level: debug|info|warn|error (default: debug)
  --error-only          Shortcut for --level error
  --module <name>       Exact module filter (case-insensitive)
  --grep <text>         Case-insensitive substring filter on module/message
  --raw                 Print matching JSONL lines instead of formatted text
  --once                Print matching lines and exit without following
  -h, --help            Show this help
EOF
}

resolve_base_path() {
  local path="$1"

  if [ -f "$path/.git" ]; then
    local gitdir
    gitdir="$(sed -n 's/^gitdir: //p' "$path/.git")"
    if [ -n "$gitdir" ]; then
      case "$gitdir" in
        */.git/worktrees/*)
          echo "${gitdir%/.git/worktrees/*}"
          return
          ;;
        */.git)
          echo "${gitdir%/.git}"
          return
          ;;
      esac
    fi
  fi

  if [ -d "$path/.git" ]; then
    echo "$path"
    return
  fi

  if command -v git >/dev/null 2>&1; then
    local git_root
    git_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$git_root" ]; then
      echo "$git_root"
      return
    fi
  fi

  echo "$path"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 2
  fi
}

require_value() {
  local opt="$1"
  local next="${2:-}"
  if [ -z "$next" ] || [[ "$next" == --* ]]; then
    echo "ERROR: $opt requires a value" >&2
    usage >&2
    exit 2
  fi
}

current_log_date() {
  if [ -n "$DATE_OVERRIDE" ]; then
    echo "$DATE_OVERRIDE"
  else
    date +%F
  fi
}

log_path_for_date() {
  local date_key="$1"
  printf '%s/system_log_%s.jsonl\n' "$LOG_DIR" "$date_key"
}

upper_ascii() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

validate_args() {
  if ! [[ "$TAIL_LINES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --lines must be a non-negative integer" >&2
    exit 2
  fi

  case "$(upper_ascii "$MIN_LEVEL")" in
    DEBUG|INFO|WARN|ERROR) ;;
    *)
      echo "ERROR: --level must be one of debug|info|warn|error" >&2
      exit 2
      ;;
  esac

  if [ -n "$DATE_OVERRIDE" ] && ! [[ "$DATE_OVERRIDE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: --date must be YYYY-MM-DD" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-path)
      require_value "$1" "${2:-}"
      BASE_PATH_OVERRIDE="${2:-}"
      shift 2
      ;;
    --date)
      require_value "$1" "${2:-}"
      DATE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --lines)
      require_value "$1" "${2:-}"
      TAIL_LINES="${2:-}"
      shift 2
      ;;
    --level)
      require_value "$1" "${2:-}"
      MIN_LEVEL="${2:-}"
      shift 2
      ;;
    --error-only)
      MIN_LEVEL="ERROR"
      shift
      ;;
    --module)
      require_value "$1" "${2:-}"
      MODULE_FILTER="${2:-}"
      shift 2
      ;;
    --grep)
      require_value "$1" "${2:-}"
      MESSAGE_FILTER="${2:-}"
      shift 2
      ;;
    --raw)
      RAW_MODE=1
      shift
      ;;
    --once)
      FOLLOW_MODE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd jq
require_cmd tail
validate_args

BASE_PATH_INPUT="${BASE_PATH_OVERRIDE:-${MASC_BASE_PATH:-${HOME:-$REPO_ROOT}}}"
BASE_PATH="$(resolve_base_path "$BASE_PATH_INPUT")"
LOG_DIR="$BASE_PATH/.masc/logs"

jq_filter='
  def rank:
    ascii_upcase
    | if . == "DEBUG" then 0
      elif . == "INFO" then 1
      elif . == "WARN" or . == "WARNING" then 2
      elif . == "ERROR" or . == "FATAL" then 3
      else 1 end;

  select(
    ((.normalized_level // .level // "INFO") | rank) >= ($min_level | rank)
    and ($module == "" or ((.module // "") | ascii_downcase) == ($module | ascii_downcase))
    and (
      $pattern == ""
      or ((((.module // "") + " " + (.message // "")) | ascii_downcase) | contains($pattern | ascii_downcase))
    )
  )
'

format_line() {
  local line="$1"
  local formatted
  formatted="$(
    printf '%s\n' "$line" \
      | jq -r \
        --arg min_level "$MIN_LEVEL" \
        --arg module "$MODULE_FILTER" \
        --arg pattern "$MESSAGE_FILTER" \
        "$jq_filter | [.ts // \"-\", (.normalized_level // .level // \"INFO\"), (.module // \"-\"), (.message // \"\")] | @tsv" \
        2>/dev/null || true
  )"

  if [ -n "$formatted" ]; then
    local ts level module message
    IFS=$'\t' read -r ts level module message <<< "$formatted"
    printf '%s %-5s %-24s %s\n' "$ts" "$level" "$module" "$message"
  fi
}

process_line() {
  local line="$1"

  if [ "$RAW_MODE" -eq 1 ]; then
    printf '%s\n' "$line" \
      | jq -c \
        --arg min_level "$MIN_LEVEL" \
        --arg module "$MODULE_FILTER" \
        --arg pattern "$MESSAGE_FILTER" \
        "$jq_filter" \
        2>/dev/null || true
  else
    format_line "$line"
  fi
}

wait_for_log_file() {
  local log_path="$1"
  local notice_printed=0

  while [ ! -f "$log_path" ]; do
    if [ "$FOLLOW_MODE" -eq 0 ]; then
      echo "ERROR: log file not found: $log_path" >&2
      exit 1
    fi
    if [ "$notice_printed" -eq 0 ]; then
      echo "[logs-follow] waiting for $log_path" >&2
      notice_printed=1
    fi
    sleep 1
  done
}

run_once() {
  local log_path="$1"
  local lines
  lines="$(tail -n "$TAIL_LINES" "$log_path")" || {
    echo "ERROR: failed to read log file: $log_path" >&2
    exit 1
  }
  printf '%s\n' "$lines" | while IFS= read -r line; do
    process_line "$line"
  done
}

TAIL_PID=""
TAIL_PIPE_DIR=""
TAIL_PIPE_PATH=""
DATE_WATCH_PID=""

cleanup() {
  if [ -n "${TAIL_PID:-}" ]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi
  if [ -n "${DATE_WATCH_PID:-}" ]; then
    kill "$DATE_WATCH_PID" 2>/dev/null || true
    wait "$DATE_WATCH_PID" 2>/dev/null || true
  fi
  if [ -n "${TAIL_PIPE_DIR:-}" ] && [ -d "$TAIL_PIPE_DIR" ]; then
    rm -rf "$TAIL_PIPE_DIR"
  fi
}

trap cleanup EXIT INT TERM

follow_for_date() {
  local date_key="$1"
  local rotate_daily="$2"
  local log_path
  log_path="$(log_path_for_date "$date_key")"

  wait_for_log_file "$log_path"
  echo "[logs-follow] following $log_path (level>=$(upper_ascii "$MIN_LEVEL")${MODULE_FILTER:+ module=$MODULE_FILTER}${MESSAGE_FILTER:+ grep=$MESSAGE_FILTER})" >&2

  TAIL_PIPE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/masc-log-follow.XXXXXX")"
  TAIL_PIPE_PATH="$TAIL_PIPE_DIR/stream"
  mkfifo "$TAIL_PIPE_PATH"

  tail -n "$TAIL_LINES" -F "$log_path" >"$TAIL_PIPE_PATH" &
  TAIL_PID="$!"

  if [ "$rotate_daily" = "1" ]; then
    (
      while [ "$(date +%F)" = "$date_key" ]; do
        sleep 1
      done
      kill "$TAIL_PID" 2>/dev/null || true
    ) &
    DATE_WATCH_PID="$!"
  fi

  while IFS= read -r line; do
    process_line "$line"
  done < "$TAIL_PIPE_PATH"

  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""

  if [ -n "${DATE_WATCH_PID:-}" ]; then
    kill "$DATE_WATCH_PID" 2>/dev/null || true
    wait "$DATE_WATCH_PID" 2>/dev/null || true
    DATE_WATCH_PID=""
  fi

  rm -rf "$TAIL_PIPE_DIR"
  TAIL_PIPE_DIR=""
  TAIL_PIPE_PATH=""
}

if [ ! -d "$LOG_DIR" ] && [ "$FOLLOW_MODE" -eq 0 ]; then
  echo "ERROR: log directory not found: $LOG_DIR" >&2
  exit 1
fi

if [ "$FOLLOW_MODE" -eq 0 ]; then
  target_date="$(current_log_date)"
  target_path="$(log_path_for_date "$target_date")"
  run_once "$target_path"
  exit 0
fi

while true; do
  date_key="$(current_log_date)"
  if [ -n "$DATE_OVERRIDE" ]; then
    follow_for_date "$date_key" 0
    exit 0
  fi
  follow_for_date "$date_key" 1
done
