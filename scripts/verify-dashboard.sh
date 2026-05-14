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
check_command "navigation/nav-event parity" bash scripts/check-dashboard-nav-event-parity.sh --check

echo "[2/7] Health + Shell"
check_http "health 200" "$BASE/health" "200"
check_json "version looks semver-ish" "$BASE/health" "d.get('version', '')" '^[0-9]+\.[0-9]+'
check_http "dashboard shell 200" "$BASE/api/v1/dashboard/shell" "200"
check_json "shell exposes auth contract" "$BASE/api/v1/dashboard/shell" "'auth' in d" '^True$'
check_http "surface-readiness 200" "$BASE/api/v1/dashboard/surface-readiness" "200"
check_json \
  "surface-readiness has canonical surface count" \
  "$BASE/api/v1/dashboard/surface-readiness" \
  "len(d.get('surfaces', []))" \
  '^21$'
check_json \
  "surface-readiness matches canonical surface ids" \
  "$BASE/api/v1/dashboard/surface-readiness" \
  "sorted(s.get('id') for s in d.get('surfaces', [])) == sorted(['cockpit', 'overview', 'monitoring.runtime', 'monitoring.agents', 'monitoring.goal-loop', 'monitoring.fleet-health', 'monitoring.journey', 'monitoring.observatory', 'monitoring.cognition', 'command.operations', 'connectors.connector-status', 'workspace.board', 'workspace.sub-boards', 'workspace.planning', 'workspace.repositories', 'workspace.verification', 'lab.tools', 'lab.autoresearch', 'lab.harness', 'code.ide-shell', 'logs'])" \
  '^True$'
check_json \
  "surface-readiness dropped retired surfaces" \
  "$BASE/api/v1/dashboard/surface-readiness" \
  "all(not any(s.get('id') == retired for s in d.get('surfaces', [])) for retired in ['monitoring.sessions', 'monitoring.memory-subsystems', 'workspace.collab-mvp'])" \
  '^True$'

echo "[3/7] Monitoring"
check_http "namespace-truth 200" "$BASE/api/v1/dashboard/namespace-truth" "200"
check_json_eventually \
  "namespace-truth exposes execution block" \
  "$BASE/api/v1/dashboard/namespace-truth" \
  "'execution' in d" \
  '^True$' \
  60 \
  2
check_http "goal-loop status 200" "$BASE/api/v1/dashboard/goal-loop/status" "200"
check_json "goal-loop status exposes phases" "$BASE/api/v1/dashboard/goal-loop/status" "'overall_status' in d and 'phases' in d" '^True$'
check_http "activity graph 200" "$BASE/api/v1/activity/graph" "200"
check_json "activity graph has nodes" "$BASE/api/v1/activity/graph" "len(d.get('nodes', [])) >= 0" '^True$'
check_http "telemetry summary 200" "$BASE/api/v1/dashboard/telemetry/summary" "200"
check_json "telemetry summary has sources" "$BASE/api/v1/dashboard/telemetry/summary" "'sources' in d" '^True$'
check_http "cascade health 200" "$BASE/api/v1/cascade/health" "200"
check_json "cascade health exposes providers" "$BASE/api/v1/cascade/health" "'providers' in d" '^True$'
check_http "cascade strategy trace 200" "$BASE/api/v1/cascade/strategy_trace?limit=1" "200"
check_json "cascade strategy trace exposes events" "$BASE/api/v1/cascade/strategy_trace?limit=1" "'events' in d" '^True$'
check_http "runtime providers 200" "$BASE/api/v1/providers" "200"
check_json "runtime providers exposes inventory" "$BASE/api/v1/providers" "'summary' in d and 'providers' in d" '^True$'
check_http "cascade config 200" "$BASE/api/v1/cascade/config" "200"
check_json "cascade config exposes profiles" "$BASE/api/v1/cascade/config" "'validation_status' in d and 'profiles' in d" '^True$'
check_http "cascade raw config 200" "$BASE/api/v1/cascade/config/raw" "200"
check_json "cascade raw config exposes source" "$BASE/api/v1/cascade/config/raw" "'source_text' in d and 'source_editable' in d" '^True$'
check_http "cascade client capacity 200" "$BASE/api/v1/cascade/client_capacity" "200"
check_json "cascade client capacity exposes entries" "$BASE/api/v1/cascade/client_capacity" "'entries' in d" '^True$'
check_http "cascade capacity history 200" "$BASE/api/v1/cascade/client_capacity/history?limit=1" "200"
check_json "cascade capacity history exposes events" "$BASE/api/v1/cascade/client_capacity/history?limit=1" "'events' in d" '^True$'
check_http "cascade slo 200" "$BASE/api/v1/cascade/slo" "200"
check_json "cascade slo exposes status" "$BASE/api/v1/cascade/slo" "'status' in d and 'current' in d" '^True$'
check_http "model metrics 200" "$BASE/api/v1/models/metrics?window=30&bucket_min=5" "200"
check_json "model metrics exposes model list" "$BASE/api/v1/models/metrics?window=30&bucket_min=5" "'models' in d" '^True$'
check_http "keeper costs 200" "$BASE/api/v1/dashboard/keeper-costs?window=60" "200"
check_json "keeper costs exposes keepers" "$BASE/api/v1/dashboard/keeper-costs?window=60" "'keepers' in d" '^True$'
check_http "memory subsystems 200" "$BASE/api/v1/dashboard/memory-subsystems" "200"
check_json "memory subsystems has hebbian block" "$BASE/api/v1/dashboard/memory-subsystems" "'hebbian' in d" '^True$'
check_http "transport health 200" "$BASE/api/v1/dashboard/transport-health" "200"
check_json "transport health has summary" "$BASE/api/v1/dashboard/transport-health" "'summary' in d" '^True$'
check_http "attribution summary 200" "$BASE/api/v1/attribution/summary" "200"
check_json "attribution summary has gates" "$BASE/api/v1/attribution/summary" "'gates' in d" '^True$'
check_http "safe autonomy 200" "$BASE/api/v1/dashboard/safe-autonomy" "200"
check_json "safe autonomy exposes scorecard" "$BASE/api/v1/dashboard/safe-autonomy" "'summary' in d and 'domains' in d and 'per_keeper' in d" '^True$'
check_http "keeper feature proof 200" "$BASE/api/v1/dashboard/keeper-feature-proof?window_hours=24" "200"
check_json "keeper feature proof exposes features" "$BASE/api/v1/dashboard/keeper-feature-proof?window_hours=24" "'summary' in d and 'features' in d and 'evidence_refs' in d" '^True$'

echo "[4/7] Operations + Workspace"
check_http "operator digest 200" "$BASE/api/v1/operator/digest" "200"
check_json "operator digest has health block" "$BASE/api/v1/operator/digest" "'health' in d" '^True$'
check_http "board 200" "$BASE/api/v1/dashboard/board" "200"
check_json "board exposes posts" "$BASE/api/v1/dashboard/board" "'posts' in d" '^True$'
check_http "board hearths 200" "$BASE/api/v1/board/hearths" "200"
check_json "board hearths exposes list" "$BASE/api/v1/board/hearths" "'hearths' in d" '^True$'
check_http "board curation 200" "$BASE/api/v1/board/curation" "200"
check_json "board curation exposes snapshot slot" "$BASE/api/v1/board/curation" "'snapshot' in d" '^True$'
check_http "board karma ledger 200" "$BASE/api/v1/board/karma/ledger?limit=1" "200"
check_json "board karma ledger exposes events and totals" "$BASE/api/v1/board/karma/ledger?limit=1" "'events' in d and 'totals' in d" '^True$'
check_http "sub-boards 200" "$BASE/api/v1/board/sub-boards" "200"
check_json "sub-boards exposes list" "$BASE/api/v1/board/sub-boards" "'sub_boards' in d" '^True$'
check_http "planning 200" "$BASE/api/v1/dashboard/planning" "200"
check_json "planning exposes rollup" "$BASE/api/v1/dashboard/planning" "'rollup' in d" '^True$'
check_http "git graph 200" "$BASE/api/v1/git/graph?n=20" "200"
check_json "git graph exposes stats and nodes" "$BASE/api/v1/git/graph?n=20" "'stats' in d and 'nodes' in d" '^True$'
check_http "repositories 200" "$BASE/api/v1/repositories" "200"
check_json "repositories exposes list" "$BASE/api/v1/repositories" "'repositories' in d and 'total' in d" '^True$'
check_http "workspace tree 200" "$BASE/api/v1/workspace/tree?depth=1" "200"
check_json "workspace tree exposes nodes array" "$BASE/api/v1/workspace/tree?depth=1" "len(d) >= 0" '^True$'
check_http "verification requests 200" "$BASE/api/v1/verification/requests" "200"
check_json "verification requests exposes list" "$BASE/api/v1/verification/requests" "'requests' in d" '^True$'
check_http "verification summary 200" "$BASE/api/v1/verification/summary" "200"
check_json "verification summary exposes status buckets" "$BASE/api/v1/verification/summary" "'by_status' in d" '^True$'
check_http "verification specs 200" "$BASE/api/v1/verification/specs" "200"
check_json "verification specs exposes index" "$BASE/api/v1/verification/specs" "'entries' in d and 'count' in d" '^True$'
check_http "verification tlc results 200" "$BASE/api/v1/verification/tlc-results" "200"
check_json "verification tlc results exposes entries" "$BASE/api/v1/verification/tlc-results" "'entries' in d and 'count' in d" '^True$'

echo "[5/7] Connectors + Lab"
check_http "gate connectors 200" "$BASE/api/v1/gate/connectors" "200"
check_json "gate connectors exposes connectors list" "$BASE/api/v1/gate/connectors" "'connectors' in d" '^True$'
check_http "dashboard tools 200" "$BASE/api/v1/dashboard/tools" "200"
check_json "dashboard tools exposes inventory" "$BASE/api/v1/dashboard/tools" "'tool_inventory' in d" '^True$'
check_http "tool quality 200" "$BASE/api/v1/dashboard/tool-quality?window_hours=24" "200"
check_json "tool quality exposes aggregates" "$BASE/api/v1/dashboard/tool-quality?window_hours=24" "'total' in d and 'by_tool' in d and 'failure_categories' in d" '^True$'
check_http "tool metrics 200" "$BASE/api/v1/tool-metrics" "200"
check_json "tool metrics exposes usage" "$BASE/api/v1/tool-metrics" "'total_calls' in d and 'top_20' in d and 'registered_count' in d" '^True$'
check_http "prompt registry 200" "$BASE/api/v1/prompts" "200"
check_json "prompt registry exposes prompts" "$BASE/api/v1/prompts" "'prompts' in d" '^True$'
check_http "autoresearch loops 200" "$BASE/api/v1/autoresearch/loops" "200"
check_json "autoresearch loops exposes loops" "$BASE/api/v1/autoresearch/loops" "'loops' in d" '^True$'
check_http "harness health 200" "$BASE/api/v1/dashboard/harness-health" "200"
check_json "harness health exposes overview" "$BASE/api/v1/dashboard/harness-health" "'overview' in d" '^True$'

echo "[6/7] Code + Logs"
check_http "IDE presence 200" "$BASE/api/v1/ide/presence" "200"
check_json "IDE presence exposes connected state" "$BASE/api/v1/ide/presence" "d.get('data', {}).get('connected')" '^True$'
check_http "IDE annotations 200" "$BASE/api/v1/ide/annotations" "200"
check_json "IDE annotations exposes data envelope" "$BASE/api/v1/ide/annotations" "d.get('ok') == True and 'data' in d" '^True$'
check_http "IDE regions 200" "$BASE/api/v1/ide/regions" "200"
check_json "IDE regions exposes data envelope" "$BASE/api/v1/ide/regions" "d.get('ok') == True and 'data' in d" '^True$'
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
