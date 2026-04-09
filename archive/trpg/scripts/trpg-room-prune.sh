#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/trpg-room-prune.sh [options]

Options:
  --room-id <id>         TRPG room id to prune (default: default)
  --base-path <path>     Base path containing trpg/events.sqlite3 (default: $MASC_BASE_PATH or $HOME/me)
  --db-path <path>       Explicit sqlite db path (overrides --base-path)
  --keep-sessions <n>    Keep last N room.created sessions (default: 1)
  --apply                Apply deletion (default: dry-run)
  --vacuum               Run VACUUM after deletion (only with --apply)
  --help                 Show this help

Examples:
  scripts/trpg-room-prune.sh --room-id default
  scripts/trpg-room-prune.sh --room-id default --keep-sessions 2 --apply --vacuum
EOF
}

ROOM_ID="default"
BASE_PATH="${MASC_BASE_PATH:-${HOME}/me}"
DB_PATH=""
KEEP_SESSIONS=1
APPLY=0
VACUUM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --room-id)
      ROOM_ID="${2:-}"
      shift 2
      ;;
    --base-path)
      BASE_PATH="${2:-}"
      shift 2
      ;;
    --db-path)
      DB_PATH="${2:-}"
      shift 2
      ;;
    --keep-sessions)
      KEEP_SESSIONS="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
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

if ! [[ "$KEEP_SESSIONS" =~ ^[0-9]+$ ]] || [[ "$KEEP_SESSIONS" -lt 1 ]]; then
  echo "ERROR: --keep-sessions must be a positive integer" >&2
  exit 1
fi

if [[ -z "$DB_PATH" ]]; then
  DB_PATH="${BASE_PATH%/}/trpg/events.sqlite3"
fi

if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: sqlite db not found: $DB_PATH" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 command is required" >&2
  exit 1
fi

sql_one() {
  local sql="$1"
  sqlite3 "$DB_PATH" "$sql"
}

escape_sql() {
  # Escape single quotes for SQL string literal.
  printf "%s" "$1" | sed "s/'/''/g"
}

ROOM_ESCAPED="$(escape_sql "$ROOM_ID")"
OFFSET=$((KEEP_SESSIONS - 1))

TOTAL_BEFORE="$(sql_one "SELECT COUNT(*) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}';")"
if [[ "$TOTAL_BEFORE" -eq 0 ]]; then
  echo "No events found for room_id='${ROOM_ID}'. Nothing to do."
  exit 0
fi

SESSIONS_TOTAL="$(sql_one "SELECT COUNT(*) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}' AND event_type='room.created';")"

CUTOFF_SEQ="$(sql_one "SELECT seq FROM trpg_events WHERE room_id='${ROOM_ESCAPED}' AND event_type='room.created' ORDER BY seq DESC LIMIT 1 OFFSET ${OFFSET};")"
if [[ -z "$CUTOFF_SEQ" ]]; then
  CUTOFF_SEQ=1
fi

TO_DELETE="$(sql_one "SELECT COUNT(*) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}' AND seq < ${CUTOFF_SEQ};")"
TOTAL_AFTER_ESTIMATE=$((TOTAL_BEFORE - TO_DELETE))

echo "TRPG prune plan"
echo "  db_path         : $DB_PATH"
echo "  room_id         : $ROOM_ID"
echo "  keep_sessions   : $KEEP_SESSIONS"
echo "  sessions_total  : $SESSIONS_TOTAL"
echo "  cutoff_seq      : $CUTOFF_SEQ"
echo "  total_before    : $TOTAL_BEFORE"
echo "  delete_rows     : $TO_DELETE"
echo "  total_after_est : $TOTAL_AFTER_ESTIMATE"

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "Dry-run only. Re-run with --apply to execute."
  exit 0
fi

if [[ "$TO_DELETE" -le 0 ]]; then
  echo "No rows to delete. Done."
  exit 0
fi

BACKUP_PATH="${DB_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$DB_PATH" "$BACKUP_PATH"
echo "Backup created: $BACKUP_PATH"

sqlite3 "$DB_PATH" <<EOF
BEGIN IMMEDIATE;
DELETE FROM trpg_events
 WHERE room_id='${ROOM_ESCAPED}'
   AND seq < ${CUTOFF_SEQ};
DELETE FROM trpg_snapshots
 WHERE room_id='${ROOM_ESCAPED}';
COMMIT;
EOF

if [[ "$VACUUM" -eq 1 ]]; then
  echo "Running VACUUM..."
  sqlite3 "$DB_PATH" "VACUUM;"
fi

TOTAL_AFTER="$(sql_one "SELECT COUNT(*) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}';")"
MIN_SEQ_AFTER="$(sql_one "SELECT COALESCE(MIN(seq),0) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}';")"
MAX_SEQ_AFTER="$(sql_one "SELECT COALESCE(MAX(seq),0) FROM trpg_events WHERE room_id='${ROOM_ESCAPED}';")"

echo "Prune completed"
echo "  total_after : $TOTAL_AFTER"
echo "  seq_range   : $MIN_SEQ_AFTER..$MAX_SEQ_AFTER"
