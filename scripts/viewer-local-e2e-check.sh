#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_PING_TIMEOUT_SEC="${MCP_PING_TIMEOUT_SEC:-8}"

RUN_VIEWER_BUILD=0
RUN_SMOKE=0
RUN_ROUND=0

ROUNDS="${ROUNDS:-1}"
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-45}"
ROOM_ID="${ROOM_ID:-default}"
WORLD_PRESET_ID="${WORLD_PRESET_ID:-}"
DM_PRESET_ID="${DM_PRESET_ID:-}"
PARTY_SIZE="${PARTY_SIZE:-4}"
POOL_SIZE="${POOL_SIZE:-6}"
KEEPER_MODELS="${KEEPER_MODELS:-}"

FAIL_COUNT=0
STEP_INDEX=0
TOTAL_STEPS=4
LOG_DIR="${TMPDIR:-/tmp}/masc-viewer-local-e2e-$$"

STEP_LABELS=()
STEP_RESULTS=()
STEP_LOGS=()

usage() {
  cat <<'EOF'
viewer-local-e2e-check.sh

로컬 TRPG + Viewer 체크리스트를 순서대로 실행합니다.

기본 실행:
  1) 필수 커맨드 점검
  2) MCP endpoint reachability 점검
  3) GAME-VIEW precondition contract harness
  4) TRPG session contract harness

옵션:
  --build-viewer             viewer WASM 빌드(trunk build) 포함
  --run-smoke                grimland smoke workload 포함
  --run-round                smoke에 trpg.round.run 실행 포함 (암시적으로 --run-smoke)
  --rounds N                 smoke 라운드 수 (기본 1)
  --round-timeout-sec N      round timeout (기본 45)
  --room-id ID               smoke room_id (기본 default)
  --world-preset-id ID       smoke world preset
  --dm-preset-id ID          smoke DM preset
  --party-size N             smoke party size (기본 4)
  --pool-size N              smoke pool size (기본 6)
  --keeper-models CSV        smoke keeper 모델 (예: ollama:glm-4.7-flash)
  --mcp-url URL              MCP endpoint (기본 http://127.0.0.1:8935/mcp)
  --help                     도움말

예시:
  scripts/viewer-local-e2e-check.sh
  scripts/viewer-local-e2e-check.sh --build-viewer
  scripts/viewer-local-e2e-check.sh --run-smoke --keeper-models "ollama:glm-4.7-flash"
  scripts/viewer-local-e2e-check.sh --run-round --rounds 2 --keeper-models "gemini:gemini-2.5-flash"
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

record_step() {
  STEP_LABELS+=("$1")
  STEP_RESULTS+=("$2")
  STEP_LOGS+=("$3")
}

run_step() {
  local label="$1"
  shift

  STEP_INDEX=$((STEP_INDEX + 1))
  local slug
  slug="$(printf "%s" "$label" | tr ' ' '_' | tr -cd '[:alnum:]_.-')"
  local log_file="$LOG_DIR/$(printf '%02d' "$STEP_INDEX")-$slug.log"

  printf '\n[%d/%d] %s\n' "$STEP_INDEX" "$TOTAL_STEPS" "$label"
  if "$@" >"$log_file" 2>&1; then
    echo "PASS"
    record_step "$label" "PASS" "$log_file"
    return 0
  else
    local rc=$?
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL (rc=$rc)"
    echo "---- tail -n 40 $log_file ----"
    tail -n 40 "$log_file" || true
    record_step "$label" "FAIL(rc=$rc)" "$log_file"
  fi
  return 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

step_check_commands() {
  local missing=()
  local cmd
  for cmd in curl jq; do
    if ! require_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "$RUN_VIEWER_BUILD" -eq 1 ] && ! require_cmd trunk; then
    missing+=("trunk")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing required commands: ${missing[*]}"
    return 1
  fi
}

step_check_mcp() {
  local response
  response="$(curl -sS -m "$MCP_PING_TIMEOUT_SEC" -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"
  if [ -z "$(printf "%s" "$response" | tr -d '[:space:]')" ]; then
    echo "MCP endpoint returned empty response: $MCP_URL"
    return 1
  fi
}

step_viewer_build() {
  (cd "$REPO_ROOT" && scripts/viewer-trunk.sh build)
}

step_game_view_contract() {
  (cd "$REPO_ROOT" && MCP_URL="$MCP_URL" scripts/harness_game_view_precondition.sh)
}

step_trpg_session_contract() {
  local session_id="viewer-local-e2e-$(date +%s)-$$"
  (cd "$REPO_ROOT" && MCP_URL="$MCP_URL" SESSION_ID="$session_id" scripts/harness_trpg_session_contract.sh)
}

step_trpg_smoke() {
  local model_csv
  model_csv="$(trim "$KEEPER_MODELS")"
  if [ -z "$model_csv" ]; then
    echo "--run-smoke requires --keeper-models (or KEEPER_MODELS env)"
    return 1
  fi

  (cd "$REPO_ROOT" && \
    MCP_URL="$MCP_URL" \
    ROOM_ID="$ROOM_ID" \
    WORLD_PRESET_ID="$WORLD_PRESET_ID" \
    DM_PRESET_ID="$DM_PRESET_ID" \
    PARTY_SIZE="$PARTY_SIZE" \
    POOL_SIZE="$POOL_SIZE" \
    RUN_ROUND="$RUN_ROUND" \
    ROUNDS="$ROUNDS" \
    ROUND_TIMEOUT_SEC="$ROUND_TIMEOUT_SEC" \
    KEEPER_MODELS="$model_csv" \
    scripts/run_trpg_grimland_smoke.sh)
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build-viewer)
      RUN_VIEWER_BUILD=1
      ;;
    --run-smoke)
      RUN_SMOKE=1
      ;;
    --run-round)
      RUN_SMOKE=1
      RUN_ROUND=1
      ;;
    --rounds)
      shift
      ROUNDS="${1:-}"
      ;;
    --round-timeout-sec)
      shift
      ROUND_TIMEOUT_SEC="${1:-}"
      ;;
    --room-id)
      shift
      ROOM_ID="${1:-}"
      ;;
    --world-preset-id)
      shift
      WORLD_PRESET_ID="${1:-}"
      ;;
    --dm-preset-id)
      shift
      DM_PRESET_ID="${1:-}"
      ;;
    --party-size)
      shift
      PARTY_SIZE="${1:-}"
      ;;
    --pool-size)
      shift
      POOL_SIZE="${1:-}"
      ;;
    --keeper-models)
      shift
      KEEPER_MODELS="${1:-}"
      ;;
    --mcp-url)
      shift
      MCP_URL="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$RUN_VIEWER_BUILD" -eq 1 ]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
if [ "$RUN_SMOKE" -eq 1 ]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

mkdir -p "$LOG_DIR"

echo "viewer-local-e2e-check"
echo "  MCP_URL=$MCP_URL"
echo "  RUN_VIEWER_BUILD=$RUN_VIEWER_BUILD"
echo "  RUN_SMOKE=$RUN_SMOKE"
echo "  RUN_ROUND=$RUN_ROUND"
echo "  LOG_DIR=$LOG_DIR"

run_step "command prerequisites" step_check_commands
run_step "mcp endpoint reachable" step_check_mcp
if [ "$RUN_VIEWER_BUILD" -eq 1 ]; then
  run_step "viewer build (trunk build)" step_viewer_build
fi
run_step "harness game-view precondition" step_game_view_contract
run_step "harness trpg session contract" step_trpg_session_contract
if [ "$RUN_SMOKE" -eq 1 ]; then
  run_step "workload trpg grimland smoke" step_trpg_smoke
fi

echo
echo "===== SUMMARY ====="
idx=0
while [ "$idx" -lt "${#STEP_LABELS[@]}" ]; do
  printf '%-42s : %-12s (%s)\n' \
    "${STEP_LABELS[$idx]}" "${STEP_RESULTS[$idx]}" "${STEP_LOGS[$idx]}"
  idx=$((idx + 1))
done

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL ($FAIL_COUNT step(s) failed)"
  exit 1
fi

echo "RESULT: PASS"
