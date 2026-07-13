#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_PING_TIMEOUT_SEC="${MCP_PING_TIMEOUT_SEC:-8}"
MCP_PING_RETRY_COUNT="${MCP_PING_RETRY_COUNT:-12}"
MCP_PING_RETRY_DELAY_SEC="${MCP_PING_RETRY_DELAY_SEC:-1}"

RUN_VIEWER_BUILD=0
RUN_SMOKE=0
RUN_ROUND=0

ROUNDS="${ROUNDS:-1}"
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-45}"
WORKSPACE_ID="${WORKSPACE_ID:-}"
PARTY_SIZE="${PARTY_SIZE:-4}"
POOL_SIZE="${POOL_SIZE:-6}"
KEEPER_MODELS="${KEEPER_MODELS:-}"

FAIL_COUNT=0
STEP_INDEX=0
TOTAL_STEPS=4
LOG_DIR="${TMPDIR:-/tmp}/masc-viewer-local-e2e-$$"
HARNESS_HELPERS_LOADED=0
VIEWER_MCP_SESSION_ID=""

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
  --workspace-id ID               smoke workspace_id (기본: 자동 생성)
  --party-size N             smoke party size (기본 4)
  --pool-size N              smoke pool size (기본 6)
  --keeper-models CSV        smoke keeper 모델 (예: glm:auto)
  --mcp-url URL              MCP endpoint (기본 http://127.0.0.1:8935/mcp)
  --help                     도움말

예시:
  scripts/viewer-local-e2e-check.sh
  scripts/viewer-local-e2e-check.sh --build-viewer
  scripts/viewer-local-e2e-check.sh --run-smoke --keeper-models "glm:auto"
  scripts/viewer-local-e2e-check.sh --run-round --rounds 2 --keeper-models "auto:auto"
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

resolve_repo_script() {
  local script_path="$1"
  local primary="$REPO_ROOT/$script_path"
  local archived="$REPO_ROOT/archive/trpg/$script_path"
  local archived_actual=""

  case "$script_path" in
    scripts/harness_game_view_precondition.sh)
      archived_actual="$REPO_ROOT/archive/trpg/scripts/game_view_precondition.sh"
      ;;
    scripts/harness_trpg_session_contract.sh)
      archived_actual="$REPO_ROOT/archive/trpg/scripts/trpg_session_contract.sh"
      ;;
    scripts/run_trpg_grimland_smoke.sh)
      archived_actual="$REPO_ROOT/archive/trpg/scripts/trpg_grimland_smoke.sh"
      ;;
  esac

  if [ -x "$primary" ]; then
    printf '%s\n' "$primary"
    return 0
  fi
  if [ -n "$archived_actual" ] && [ -x "$archived_actual" ]; then
    printf '%s\n' "$archived_actual"
    return 0
  fi
  if [ -x "$archived" ]; then
    printf '%s\n' "$archived"
    return 0
  fi

  echo "missing harness script: $script_path" >&2
  echo "checked: $primary" >&2
  if [ -n "$archived_actual" ]; then
    echo "checked: $archived_actual" >&2
  fi
  echo "checked: $archived" >&2
  return 1
}

ensure_mcp_harness() {
  if [ "$HARNESS_HELPERS_LOADED" -eq 1 ]; then
    return 0
  fi
  export MCP_SESSION_ID="${MCP_SESSION_ID:-viewer-local-e2e-$$}"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/harness/lib/test_framework.sh"
  HARNESS_HELPERS_LOADED=1
}

ensure_viewer_mcp_session() {
  ensure_mcp_harness
  if [ -n "$VIEWER_MCP_SESSION_ID" ]; then
    return 0
  fi

  local headers_file body_file
  headers_file="$(mcp_mktemp_file "viewer-mcp-init-headers")"
  body_file="$(mcp_mktemp_file "viewer-mcp-init-body")"

  if ! curl -sS -m 30 -D "$headers_file" -o "$body_file" -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"viewer-local-e2e","version":"1.0"},"capabilities":{}}}' \
    >/dev/null; then
    rm -f "$headers_file" "$body_file"
    echo "failed to initialize MCP session" >&2
    return 1
  fi

  VIEWER_MCP_SESSION_ID="$(
    awk '
      tolower($0) ~ /^mcp-session-id:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }
    ' "$headers_file"
  )"

  rm -f "$headers_file" "$body_file"
  [ -n "$VIEWER_MCP_SESSION_ID" ]
}

viewer_call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw

  ensure_viewer_mcp_session
  raw="$(curl -sS -m 60 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $VIEWER_MCP_SESSION_ID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"

  if printf '%s' "$raw" | rg -q '^data:'; then
    printf '%s' "$raw" | sed -n 's/^data: //p' | tail -n1
  else
    printf '%s' "$raw"
  fi
}

viewer_extract_is_error() {
  jq -r '
    if .error then "true"
    else try (.result.isError | tostring) catch "false"
    end
  '
}

viewer_extract_text() {
  jq -r '
    if .error then (.error.message // "")
    else try .result.content[0].text catch ""
    end
  '
}

viewer_extract_result_json() {
  jq -c '
    if .error then {}
    else
      try (.result.content[0].text | fromjson | if has("result") and .result != null then .result else . end)
      catch {}
    end
  '
}

tool_text_json() {
  jq -c 'try (.result.content[0].text | fromjson) catch empty'
}

extract_result_json() {
  extract_result
}

extract_is_error() {
  jq -r 'try (.result.isError) catch "false"'
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
  local attempt=1
  while [ "$attempt" -le "$MCP_PING_RETRY_COUNT" ]; do
    if response="$(curl -sS -m "$MCP_PING_TIMEOUT_SEC" -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"; then
      if [ -n "$(printf "%s" "$response" | LC_ALL=C tr -d '[:space:]')" ]; then
        return 0
      fi
    fi
    if [ "$attempt" -lt "$MCP_PING_RETRY_COUNT" ]; then
      sleep "$MCP_PING_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done
  echo "MCP endpoint returned empty response after ${MCP_PING_RETRY_COUNT} retries: $MCP_URL"
  return 1
}

step_viewer_build() {
  (cd "$REPO_ROOT" && scripts/viewer-trunk.sh build)
}

step_game_view_contract() {
  local namespace_http_url namespace_json
  namespace_http_url="${MCP_URL%/mcp}/api/v1/namespace/current"
  if ! namespace_json="$(curl -fsS "$namespace_http_url")"; then
    echo "GET $namespace_http_url failed"
    return 1
  fi
  if ! printf '%s' "$namespace_json" | jq -e '.ok == true and (.namespace_id | type == "string")' >/dev/null; then
    echo "/api/v1/namespace/current returned unexpected payload"
    printf '%s\n' "$namespace_json"
    return 1
  fi

  local pause_raw pause_json
  pause_raw="$(viewer_call_tool 2102 "masc_pause_status" "{}")"
  pause_json="$(printf '%s' "$pause_raw" | viewer_extract_text | jq -c 'try fromjson catch {}')"
  if ! printf '%s' "$pause_json" | jq -e '.ok == true and (.paused == false or .status == "running")' >/dev/null; then
    echo "masc_pause_status returned unexpected payload"
    printf '%s\n' "$pause_json"
    return 1
  fi

  local keeper_raw keeper_json
  keeper_raw="$(viewer_call_tool 2103 "masc_keeper_list" '{"limit":10}')"
  keeper_json="$(printf '%s' "$keeper_raw" | viewer_extract_text | jq -c 'try fromjson catch {}')"
  if ! printf '%s' "$keeper_json" | jq -e '.count >= 0 and (.keepers | type == "array")' >/dev/null; then
    echo "masc_keeper_list returned unexpected payload"
    printf '%s\n' "$keeper_json"
    return 1
  fi

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
    --workspace-id)
      shift
      WORKSPACE_ID="${1:-}"
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
echo "  WORKSPACE_ID=${WORKSPACE_ID:-<auto>}"
echo "  LOG_DIR=$LOG_DIR"

run_step "command prerequisites" step_check_commands
run_step "mcp endpoint reachable" step_check_mcp
if [ "$RUN_VIEWER_BUILD" -eq 1 ]; then
  run_step "viewer build (trunk build)" step_viewer_build
fi
run_step "harness game-view precondition" step_game_view_contract

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
