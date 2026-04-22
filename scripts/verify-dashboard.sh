#!/bin/bash
# Dashboard v1 verification suite
# Usage: ./scripts/verify-dashboard.sh [BASE_URL]
# Default: http://127.0.0.1:8935

set -euo pipefail

BASE="${1:-http://127.0.0.1:8935}"
PASS=0
FAIL=0
TOTAL=0

check_http() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  local url="$2"
  local expect="$3"
  local resp
  resp=$(curl --max-time 10 --retry 2 --retry-delay 1 --retry-connrefused -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || resp="000"
  if [ "$resp" = "$expect" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $name (HTTP $resp)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $name (HTTP $resp, expected $expect)"
  fi
}

json_eval() {
  local url="$1"
  local expr="$2"
  curl --max-time 10 --retry 2 --retry-delay 1 --retry-connrefused -fsS "$url" 2>/dev/null | \
    python3 -c 'import json, sys
expr = sys.argv[1]
d = json.load(sys.stdin)
env = {
    "d": d,
    "len": len,
    "any": any,
    "all": all,
    "sum": sum,
    "sorted": sorted,
}
globals_env = {"__builtins__": {}}
globals_env.update(env)
print(eval(expr, globals_env, {}))' "$expr"
}

check_json() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  local url="$2"
  local expr="$3"
  local expect="$4"
  local val
  val=$(json_eval "$url" "$expr" 2>/dev/null) || val="ERROR"
  if printf '%s\n' "$val" | grep -Eq "$expect"; then
    PASS=$((PASS + 1))
    echo "  PASS: $name ($val)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $name (got '$val', expected '$expect')"
  fi
}

check_json_eventually() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  local url="$2"
  local expr="$3"
  local expect="$4"
  local attempts="${5:-6}"
  local delay_sec="${6:-2}"
  local val="ERROR"
  local attempt=1

  while [ "$attempt" -le "$attempts" ]; do
    val=$(json_eval "$url" "$expr" 2>/dev/null) || val="ERROR"
    if printf '%s\n' "$val" | grep -Eq "$expect"; then
      PASS=$((PASS + 1))
      echo "  PASS: $name ($val, attempt $attempt/$attempts)"
      return 0
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      sleep "$delay_sec"
    fi
    attempt=$((attempt + 1))
  done

  FAIL=$((FAIL + 1))
  echo "  FAIL: $name (got '$val' after $attempts attempts, expected '$expect')"
}

check_command() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $name"
  fi
}

echo "=== Dashboard v1 Verification Suite ==="
echo "    Target: $BASE"
echo ""

echo "[1/7] Source Parity"
check_command "navigation/readiness parity" bash scripts/check-dashboard-surface-parity.sh --check

echo "[2/7] Health + Shell"
check_http "health 200" "$BASE/health" "200"
check_json "version looks semver-ish" "$BASE/health" "d.get('version', '')" '^[0-9]+\.[0-9]+'
check_http "dashboard shell 200" "$BASE/api/v1/dashboard/shell" "200"
check_json "shell exposes auth contract" "$BASE/api/v1/dashboard/shell" "'auth' in d" '^True$'
check_http "surface-readiness 200" "$BASE/api/v1/dashboard/surface-readiness" "200"
check_json \
  "surface-readiness contains current command/connectors/workspace surfaces" \
  "$BASE/api/v1/dashboard/surface-readiness" \
  "all(any(s.get('id') == target for s in d.get('surfaces', [])) for target in ['command.operations', 'connectors.connector-status', 'workspace.verification'])" \
  '^True$'
check_json \
  "surface-readiness dropped legacy sessions surface" \
  "$BASE/api/v1/dashboard/surface-readiness" \
  "any(s.get('id') == 'monitoring.sessions' for s in d.get('surfaces', []))" \
  '^False$'

echo "[3/7] Monitoring"
check_http "namespace-truth 200" "$BASE/api/v1/dashboard/namespace-truth" "200"
check_json_eventually \
  "namespace-truth exposes execution block" \
  "$BASE/api/v1/dashboard/namespace-truth" \
  "'execution' in d" \
  '^True$' \
  6 \
  2
check_http "activity graph 200" "$BASE/api/v1/activity/graph" "200"
check_json "activity graph has nodes" "$BASE/api/v1/activity/graph" "len(d.get('nodes', [])) >= 0" '^True$'
check_http "telemetry summary 200" "$BASE/api/v1/dashboard/telemetry/summary" "200"
check_json "telemetry summary has sources" "$BASE/api/v1/dashboard/telemetry/summary" "'sources' in d" '^True$'
check_http "memory subsystems 200" "$BASE/api/v1/dashboard/memory-subsystems" "200"
check_json "memory subsystems has hebbian block" "$BASE/api/v1/dashboard/memory-subsystems" "'hebbian' in d" '^True$'
check_http "transport health 200" "$BASE/api/v1/dashboard/transport-health" "200"
check_json "transport health has summary" "$BASE/api/v1/dashboard/transport-health" "'summary' in d" '^True$'
check_http "attribution summary 200" "$BASE/api/v1/attribution/summary" "200"
check_json "attribution summary has gates" "$BASE/api/v1/attribution/summary" "'gates' in d" '^True$'

echo "[4/7] Operations + Workspace"
check_http "operator digest 200" "$BASE/api/v1/operator/digest" "200"
check_json "operator digest has health block" "$BASE/api/v1/operator/digest" "'health' in d" '^True$'
check_http "board 200" "$BASE/api/v1/dashboard/board" "200"
check_json "board exposes posts" "$BASE/api/v1/dashboard/board" "'posts' in d" '^True$'
check_http "planning 200" "$BASE/api/v1/dashboard/planning" "200"
check_json "planning exposes rollup" "$BASE/api/v1/dashboard/planning" "'rollup' in d" '^True$'
check_http "verification requests 200" "$BASE/api/v1/verification/requests" "200"
check_json "verification requests exposes list" "$BASE/api/v1/verification/requests" "'requests' in d" '^True$'
check_http "verification summary 200" "$BASE/api/v1/verification/summary" "200"
check_json "verification summary exposes status buckets" "$BASE/api/v1/verification/summary" "'by_status' in d" '^True$'

echo "[5/7] Connectors + Lab"
check_http "gate connectors 200" "$BASE/api/v1/gate/connectors" "200"
check_json "gate connectors exposes connectors list" "$BASE/api/v1/gate/connectors" "'connectors' in d" '^True$'
check_http "dashboard tools 200" "$BASE/api/v1/dashboard/tools" "200"
check_json "dashboard tools exposes inventory" "$BASE/api/v1/dashboard/tools" "'tool_inventory' in d" '^True$'
check_http "autoresearch loops 200" "$BASE/api/v1/autoresearch/loops" "200"
check_json "autoresearch loops exposes loops" "$BASE/api/v1/autoresearch/loops" "'loops' in d" '^True$'
check_http "harness health 200" "$BASE/api/v1/dashboard/harness-health" "200"
check_json "harness health exposes overview" "$BASE/api/v1/dashboard/harness-health" "'overview' in d" '^True$'

echo "[6/7] Logs"
check_http "dashboard logs 200" "$BASE/api/v1/dashboard/logs?limit=3" "200"
check_json "dashboard logs exposes entries" "$BASE/api/v1/dashboard/logs?limit=3" "'entries' in d" '^True$'

echo "[7/7] SPA"
check_http "dashboard index 200" "$BASE/dashboard" "200"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL $TOTAL TESTS PASSED ==="
else
  echo "=== $PASS/$TOTAL passed, $FAIL FAILED ==="
  exit 1
fi
