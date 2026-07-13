#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

RUN_LOCAL_SCRIPT="${RUN_LOCAL_SCRIPT:-${ROOT_DIR}/scripts/run-local.sh}"
PORT="${PORT:-$(harness_pick_free_port)}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "/tmp/masc-run-local-fresh.XXXXXX")}"
LOG_FILE="${LOG_FILE:-$(harness_mktemp_file "masc-run-local-fresh" ".log")}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
KEEP_LOG_FILE="${KEEP_LOG_FILE:-0}"
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-45}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-10}"
SERVER_PID=""

status_code() {
  local header_file="$1"
  awk 'toupper($1) ~ /^HTTP\/[0-9.]+$/ { code=$2 } END { print code }' "$header_file"
}

header_value() {
  local header_file="$1"
  local key="$2"
  awk -v k="$key" '
    tolower($0) ~ "^" tolower(k) ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print $0
      exit
    }
  ' "$header_file"
}

normalize_json() {
  local src="$1"
  local dest="$2"
  python3 - "$src" "$dest" <<'PY'
import json
import sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
payload = None
stripped = text.lstrip()
if stripped.startswith("{") or stripped.startswith("["):
    payload = text
else:
    for line in text.splitlines():
        if line.startswith("data: "):
            payload = line[6:]
            break
if payload is None:
    raise SystemExit(f"no JSON payload found in {src}")
obj = json.loads(payload)
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(obj, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")
PY
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: required command not found: $cmd" >&2
    exit 1
  fi
}

wait_for_ready() {
  local base_url="$1"
  local ready_json="$2"
  local deadline=$(( $(date +%s) + BOOT_WAIT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS --max-time 2 "${base_url}/health/ready" >"$ready_json" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

assert_health_contract() {
  local health_json="$1"
  local expected_base="$2"
  local expected_config="$3"
  python3 - "$health_json" "$expected_base" "$expected_config" <<'PY'
import json
import sys

health_path, expected_base, expected_config = sys.argv[1:4]
health = json.load(open(health_path, encoding="utf-8"))

def fail(message):
    raise SystemExit(message)

if health.get("status") != "ok":
    fail(f"health status not ok: {health.get('status')!r}")

startup = health.get("startup") or {}
if startup.get("phase") != "ready":
    fail(f"startup phase not ready: {startup.get('phase')!r}")

paths = health.get("paths") or {}
if paths.get("effective_base_path") != expected_base:
    fail(
        f"effective_base_path mismatch: {paths.get('effective_base_path')!r} != {expected_base!r}"
    )

config_resolution = startup.get("config_resolution") or {}
if config_resolution.get("status") != "ready":
    fail(f"config_resolution.status not ready: {config_resolution.get('status')!r}")

config_root = (config_resolution.get("config_root") or {}).get("path")
if config_root != expected_config:
    fail(f"config_root.path mismatch: {config_root!r} != {expected_config!r}")
PY
}

assert_initialize_contract() {
  local initialize_json="$1"
  python3 - "$initialize_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
result = payload.get("result") or {}
server_info = result.get("serverInfo") or {}
if server_info.get("name") != "masc":
    raise SystemExit(f"unexpected serverInfo.name: {server_info.get('name')!r}")
if result.get("protocolVersion") != "2025-11-25":
    raise SystemExit(
        f"unexpected protocolVersion: {result.get('protocolVersion')!r}"
    )
PY
}

assert_tools_list_contract() {
  local tools_json="$1"
  python3 - "$tools_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
tools = ((payload.get("result") or {}).get("tools")) or []
if not tools:
    raise SystemExit("tools/list returned no tools")
names = {tool.get("name") for tool in tools if isinstance(tool, dict)}
if not ({"masc_start", "masc_status"} & names):
    raise SystemExit(
        f"tools/list missing canonical front-door tools; saw sample={sorted(list(names))[:10]!r}"
    )
PY
}

cleanup() {
  harness_stop_server "$SERVER_PID" "$STOP_WAIT_SEC"
  rm -f "${READY_JSON:-}" "${HEALTH_JSON:-}" "${INIT_HEADERS:-}" \
    "${INIT_BODY:-}" "${INIT_JSON:-}" "${NOTIFY_HEADERS:-}" \
    "${NOTIFY_BODY:-}" "${TOOLS_HEADERS:-}" "${TOOLS_BODY:-}" \
    "${TOOLS_JSON:-}"
  if [[ "$KEEP_BASE_PATH" != "1" ]]; then
    rm -rf "$BASE_PATH"
  fi
  if [[ "$KEEP_LOG_FILE" != "1" ]]; then
    rm -f "$LOG_FILE"
  fi
}
trap cleanup EXIT

require_command curl
require_command python3

[[ -x "$RUN_LOCAL_SCRIPT" ]] || {
  echo "FAIL: run-local script not executable: $RUN_LOCAL_SCRIPT" >&2
  exit 1
}

BASE_URL="http://127.0.0.1:${PORT}"
MCP_URL="${BASE_URL}/mcp"
READY_JSON="$(harness_mktemp_file "masc-run-local-ready" ".json")"
HEALTH_JSON="$(harness_mktemp_file "masc-run-local-health" ".json")"
INIT_HEADERS="$(harness_mktemp_file "masc-run-local-init" ".headers")"
INIT_BODY="$(harness_mktemp_file "masc-run-local-init" ".body")"
INIT_JSON="$(harness_mktemp_file "masc-run-local-init" ".json")"
NOTIFY_HEADERS="$(harness_mktemp_file "masc-run-local-notify" ".headers")"
NOTIFY_BODY="$(harness_mktemp_file "masc-run-local-notify" ".body")"
TOOLS_HEADERS="$(harness_mktemp_file "masc-run-local-tools" ".headers")"
TOOLS_BODY="$(harness_mktemp_file "masc-run-local-tools" ".body")"
TOOLS_JSON="$(harness_mktemp_file "masc-run-local-tools" ".json")"

rm -f "$READY_JSON" "$HEALTH_JSON" "$INIT_HEADERS" "$INIT_BODY" "$INIT_JSON" \
  "$NOTIFY_HEADERS" "$NOTIFY_BODY" "$TOOLS_HEADERS" "$TOOLS_BODY" "$TOOLS_JSON"

EXPECTED_BASE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BASE_PATH")"
EXPECTED_CONFIG="${EXPECTED_BASE}/.masc/config"

echo "[run-local-smoke] target=${EXPECTED_BASE}"
echo "[run-local-smoke] port=${PORT}"
echo "[run-local-smoke] log=${LOG_FILE}"

env \
  -u MASC_BASE_PATH \
  -u MASC_CONFIG_DIR \
  -u MASC_PERSONAS_DIR \
  -u MASC_HOST \
  -u MASC_PORT \
  -u MASC_PUBLIC_TOOLS_EXTRA \
  bash "$RUN_LOCAL_SCRIPT" --target-dir "$BASE_PATH" --host 127.0.0.1 --port "$PORT" \
  --bootstrap-only >"$LOG_FILE" 2>&1

(
  env \
    -u MASC_BASE_PATH \
    -u MASC_CONFIG_DIR \
    -u MASC_PERSONAS_DIR \
    -u MASC_HOST \
    -u MASC_PORT \
    -u MASC_PUBLIC_TOOLS_EXTRA \
    MASC_KEEPER_BOOTSTRAP_ENABLED=0 \
    bash "$RUN_LOCAL_SCRIPT" --target-dir "$BASE_PATH" --host 127.0.0.1 --port "$PORT"
) >"$LOG_FILE" 2>&1 &
SERVER_PID="$!"

if ! wait_for_ready "$BASE_URL" "$READY_JSON"; then
  echo "FAIL: run-local server did not become ready at ${BASE_URL}" >&2
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

curl -fsS --max-time 5 "${BASE_URL}/health" >"$HEALTH_JSON"
if ! assert_health_contract "$HEALTH_JSON" "$EXPECTED_BASE" "$EXPECTED_CONFIG"; then
  echo "FAIL: health contract mismatch for run-local fresh boot" >&2
  cat "$HEALTH_JSON" >&2 || true
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

curl -sS -D "$INIT_HEADERS" -o "$INIT_BODY" \
  -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"run-local-fresh-boot","version":"1.0"}}}'

init_code="$(status_code "$INIT_HEADERS")"
if [[ "$init_code" != "200" ]]; then
  echo "FAIL: initialize returned HTTP ${init_code}" >&2
  cat "$INIT_HEADERS" >&2 || true
  cat "$INIT_BODY" >&2 || true
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

normalize_json "$INIT_BODY" "$INIT_JSON"
if ! assert_initialize_contract "$INIT_JSON"; then
  echo "FAIL: initialize payload contract mismatch" >&2
  cat "$INIT_JSON" >&2 || true
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

SESSION_ID="$(header_value "$INIT_HEADERS" "Mcp-Session-Id")"
PROTOCOL_VERSION="$(header_value "$INIT_HEADERS" "Mcp-Protocol-Version")"
[[ -n "$SESSION_ID" ]] || { echo "FAIL: initialize missing Mcp-Session-Id" >&2; exit 1; }
[[ -n "$PROTOCOL_VERSION" ]] || { echo "FAIL: initialize missing Mcp-Protocol-Version" >&2; exit 1; }

curl -sS -D "$NOTIFY_HEADERS" -o "$NOTIFY_BODY" \
  -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "Mcp-Protocol-Version: ${PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'

notify_code="$(status_code "$NOTIFY_HEADERS")"
case "$notify_code" in
  200|202|204) ;;
  *)
    echo "FAIL: notifications/initialized returned HTTP ${notify_code}" >&2
    cat "$NOTIFY_HEADERS" >&2 || true
    cat "$NOTIFY_BODY" >&2 || true
    harness_print_log_tail "$LOG_FILE"
    exit 1
    ;;
esac

curl -sS -D "$TOOLS_HEADERS" -o "$TOOLS_BODY" \
  -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "Mcp-Protocol-Version: ${PROTOCOL_VERSION}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

tools_code="$(status_code "$TOOLS_HEADERS")"
if [[ "$tools_code" != "200" ]]; then
  echo "FAIL: tools/list returned HTTP ${tools_code}" >&2
  cat "$TOOLS_HEADERS" >&2 || true
  cat "$TOOLS_BODY" >&2 || true
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

normalize_json "$TOOLS_BODY" "$TOOLS_JSON"
if ! assert_tools_list_contract "$TOOLS_JSON"; then
  echo "FAIL: tools/list payload contract mismatch" >&2
  cat "$TOOLS_JSON" >&2 || true
  harness_print_log_tail "$LOG_FILE"
  exit 1
fi

echo "PASS: run-local fresh boot contract"
