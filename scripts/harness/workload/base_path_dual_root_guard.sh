#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"

RUN_ID="${RUN_ID:-base-path-dual-root-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/base_path_dual_root/$RUN_ID}"
mkdir -p "$RUN_DIR"

PORT="${PORT:-$(harness_pick_free_port)}"
SERVER_EXE="${SERVER_EXE:-}"
CONFIG_DIR="${CONFIG_DIR:-$REPO_ROOT/config}"
CWD_PATH="${CWD_PATH:-$REPO_ROOT}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-dual-root.${RUN_ID}.XXXXXX")}"
SERVER_LOG="${SERVER_LOG:-$RUN_DIR/server.log}"
HEALTH_JSON="${HEALTH_JSON:-$RUN_DIR/health.json}"
KEEP_SERVER="${KEEP_SERVER:-0}"
KEEP_PATHS="${KEEP_PATHS:-0}"

TEMP_BASE_PATH=""
TEMP_CWD_PATH=""
SERVER_PID=""

log() {
  printf '[dual-root-guard] %s\n' "$*" >&2
}

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
print(os.path.realpath(path))
PY
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    if [[ "$KEEP_SERVER" == "1" ]]; then
      log "keeping server pid=$SERVER_PID log=$SERVER_LOG"
    else
      harness_stop_server "$SERVER_PID" 10 || true
    fi
  fi

  if [[ "$KEEP_PATHS" != "1" ]]; then
    [[ -n "$TEMP_BASE_PATH" && -d "$TEMP_BASE_PATH" ]] && rm -rf "$TEMP_BASE_PATH" || true
    [[ -n "$TEMP_CWD_PATH" && -d "$TEMP_CWD_PATH" ]] && rm -rf "$TEMP_CWD_PATH" || true
  else
    [[ -n "$TEMP_BASE_PATH" ]] && log "keeping base_path fixture: $TEMP_BASE_PATH" || true
    [[ -n "$TEMP_CWD_PATH" ]] && log "keeping cwd fixture: $TEMP_CWD_PATH" || true
  fi
  return 0
}

trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "CONFIG_DIR does not exist: $CONFIG_DIR" >&2
  exit 1
fi

if [[ ! -d "$BASE_PATH" ]]; then
  mkdir -p "$BASE_PATH"
  TEMP_BASE_PATH="$BASE_PATH"
fi

if [[ ! -d "$CWD_PATH" ]]; then
  mkdir -p "$CWD_PATH"
  TEMP_CWD_PATH="$CWD_PATH"
fi

mkdir -p "$BASE_PATH/.masc"
mkdir -p "$CWD_PATH/.masc"

if [[ ! -x "${SERVER_EXE:-}" ]]; then
  SERVER_EXE="$(harness_find_server_exe "$REPO_ROOT" "$SERVER_EXE")"
fi

log "cwd_path=$CWD_PATH"
log "base_path=$BASE_PATH"
log "config_dir=$CONFIG_DIR"
log "port=$PORT"

(
  cd "$CWD_PATH"
  export MASC_BASE_PATH="$BASE_PATH"
  export MASC_CONFIG_DIR="$CONFIG_DIR"
  export MASC_PERSONAS_DIR="$CONFIG_DIR/personas"
  export MASC_STORAGE_TYPE="filesystem"
  export MASC_AUTONOMY_ENABLED="0"
  export MASC_ORCHESTRATOR_ENABLED="0"
  exec "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

if ! harness_wait_for_health "$PORT" 20; then
  if rg -qi 'dual \.masc roots are not supported|dual \.masc roots are unsupported' "$SERVER_LOG"; then
    log "pass: dual-root startup was rejected"
    exit 0
  fi
  log "server did not become healthy"
  harness_print_log_tail "$SERVER_LOG" 120
  exit 1
fi

curl -fsS "http://127.0.0.1:${PORT}/health" | jq '.' >"$HEALTH_JSON"

DUAL_ROOTS="$(jq -r '.paths.dual_masc_roots // false' "$HEALTH_JSON")"
ROOTS_DIVERGE="$(jq -r '.paths.roots_diverge // false' "$HEALTH_JSON")"
HEALTH_CWD="$(jq -r '.paths.cwd // ""' "$HEALTH_JSON")"
HEALTH_BASE_PATH="$(jq -r '.paths.effective_base_path // ""' "$HEALTH_JSON")"
HEALTH_WARNING="$(jq -r '.paths.warning // ""' "$HEALTH_JSON")"
CONFIG_ROOT="$(jq -r '.startup.config_resolution.config_root.path // ""' "$HEALTH_JSON")"
EXPECTED_CWD="$(canonical_path "$CWD_PATH")"
EXPECTED_BASE_PATH="$(canonical_path "$BASE_PATH")"
EXPECTED_CONFIG_DIR="$(canonical_path "$CONFIG_DIR")"
CANONICAL_HEALTH_CWD="$(canonical_path "$HEALTH_CWD")"
CANONICAL_HEALTH_BASE_PATH="$(canonical_path "$HEALTH_BASE_PATH")"

log "health cwd=$HEALTH_CWD"
log "health effective_base_path=$HEALTH_BASE_PATH"
log "health config_root=$CONFIG_ROOT"

if [[ "$CANONICAL_HEALTH_CWD" != "$EXPECTED_CWD" ]]; then
  echo "FAIL: health cwd mismatch: expected $CWD_PATH got $HEALTH_CWD" >&2
  exit 1
fi

if [[ "$CANONICAL_HEALTH_BASE_PATH" != "$EXPECTED_BASE_PATH" ]]; then
  echo "FAIL: effective_base_path mismatch: expected $BASE_PATH got $HEALTH_BASE_PATH" >&2
  exit 1
fi

if [[ -z "$CONFIG_ROOT" ]]; then
  echo "FAIL: config_root missing in /health payload" >&2
  echo "  health_json=$HEALTH_JSON" >&2
  exit 1
fi

if [[ "$(canonical_path "$CONFIG_ROOT")" != "$EXPECTED_CONFIG_DIR" ]]; then
  echo "FAIL: config_root mismatch: expected $CONFIG_DIR got $CONFIG_ROOT" >&2
  exit 1
fi

echo "FAIL: server became healthy under a dual-root fixture" >&2
echo "  cwd=$HEALTH_CWD" >&2
echo "  effective_base_path=$HEALTH_BASE_PATH" >&2
echo "  dual_masc_roots=$DUAL_ROOTS" >&2
echo "  roots_diverge=$ROOTS_DIVERGE" >&2
if [[ -n "$HEALTH_WARNING" ]]; then
  echo "  warning=$HEALTH_WARNING" >&2
fi
echo "  health_json=$HEALTH_JSON" >&2
exit 1
