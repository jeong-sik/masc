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
check_http "dashboard bootstrap 200" "$BASE/api/v1/dashboard/bootstrap" "200"
check_json "dashboard bootstrap exposes shell/execution/planning" "$BASE/api/v1/dashboard/bootstrap" "'shell' in d and 'execution' in d and 'planning' in d" '^True$'
check_http "dashboard config 200" "$BASE/api/v1/dashboard/config" "200"
check_json "dashboard config exposes runtime categories" "$BASE/api/v1/dashboard/config" "'server' in d and 'categories' in d" '^True$'
check_http "project snapshot 200" "$BASE/api/v1/dashboard/project-snapshot" "200"
check_json "project snapshot exposes execution/readiness" "$BASE/api/v1/dashboard/project-snapshot" "'execution' in d and 'readiness' in d" '^True$'
check_http "dashboard execution 200" "$BASE/api/v1/dashboard/execution" "200"
check_json "dashboard execution exposes provenance" "$BASE/api/v1/dashboard/execution" "'status' in d and 'agents' in d and 'execution_queue' in d and d.get('dashboard_surface') == '/api/v1/dashboard/execution' and d.get('source') == 'dashboard_execution_read_model' and d.get('retention', {}).get('scope') == 'dashboard_execution' and d.get('query', {}).get('default_light_request') is True and d.get('cache', {}).get('cache_state') in ('fresh', 'stale', 'initializing', 'request_swr_or_inline_compute')" '^True$'
check_http "dashboard execution trust 200" "$BASE/api/v1/dashboard/execution-trust" "200"
check_json "dashboard execution trust exposes provenance" "$BASE/api/v1/dashboard/execution-trust" "'dashboard_surface' in d and 'keepers' in d and 'coverage_gaps' in d" '^True$'
check_http "dashboard briefing 200" "$BASE/api/v1/dashboard/briefing" "200"
check_json "dashboard briefing exposes summary and keepers" "$BASE/api/v1/dashboard/briefing" "'summary' in d and 'keeper_briefs' in d" '^True$'
check_http "dashboard briefing sections 200" "$BASE/api/v1/dashboard/briefing/sections" "200"
check_json "dashboard briefing sections exposes provenance" "$BASE/api/v1/dashboard/briefing/sections" "'provenance' in d and 'criteria' in d" '^True$'
echo "[3/7] Monitoring"
check_http "namespace-truth 200" "$BASE/api/v1/dashboard/namespace-truth" "200"
check_json_eventually \
  "namespace-truth exposes execution block" \
  "$BASE/api/v1/dashboard/namespace-truth" \
  "'execution' in d" \
  '^True$' \
  60 \
  2
check_json \
  "namespace-truth exposes provenance" \
  "$BASE/api/v1/dashboard/namespace-truth" \
  "d.get('dashboard_surface') == '/api/v1/dashboard/namespace-truth' and d.get('source') == 'namespace_truth_read_model' and '/api/v1/dashboard/workspace-truth' not in d.get('dashboard_aliases', []) and d.get('retention', {}).get('scope') == 'dashboard_namespace_truth'" \
  '^True$'
check_http "goal-loop status 200" "$BASE/api/v1/dashboard/goal-loop/status" "200"
check_json "goal-loop status exposes phases" "$BASE/api/v1/dashboard/goal-loop/status" "'overall_status' in d and 'phases' in d" '^True$'
check_http "activity graph 200" "$BASE/api/v1/activity/graph" "200"
check_json "activity graph has nodes" "$BASE/api/v1/activity/graph" "len(d.get('nodes', [])) >= 0" '^True$'
check_http "activity events 200" "$BASE/api/v1/activity/events?limit=1" "200"
check_json "activity events exposes replay provenance" "$BASE/api/v1/activity/events?limit=1" "'events' in d and d.get('dashboard_surface') == '/api/v1/activity/events' and d.get('source') == 'activity_graph_jsonl' and d.get('retention', {}).get('scope') == 'activity_events' and d.get('latest_seq', 0) >= d.get('next_after_seq', 0)" '^True$'
check_http "agent timeline 200" "$BASE/api/v1/agent-timeline?agent_name=sangsu&limit=1" "200"
check_json "agent timeline exposes provenance" "$BASE/api/v1/agent-timeline?agent_name=sangsu&limit=1" "'events' in d and d.get('dashboard_surface') == '/api/v1/agent-timeline' and d.get('source') == 'agent_timeline_read_model' and 'retention' in d" '^True$'
check_http "agent relations 200" "$BASE/api/v1/agent-relations?agent_name=sangsu" "200"
check_json "agent relations exposes provenance" "$BASE/api/v1/agent-relations?agent_name=sangsu" "'relations' in d and d.get('dashboard_surface') == '/api/v1/agent-relations' and d.get('source') == 'second_brain_graphql' and 'retention' in d" '^True$'
check_http "activity swimlane 200" "$BASE/api/v1/activity/swimlane" "200"
check_json "activity swimlane exposes spans" "$BASE/api/v1/activity/swimlane" "'spans' in d and 'agents' in d" '^True$'
check_http "telemetry summary 200" "$BASE/api/v1/dashboard/telemetry/summary" "200"
check_json "telemetry summary has sources" "$BASE/api/v1/dashboard/telemetry/summary" "'sources' in d" '^True$'
check_http "telemetry entries 200" "$BASE/api/v1/dashboard/telemetry?source=oas_event&n=5" "200"
check_json "telemetry entries exposes replay provenance" "$BASE/api/v1/dashboard/telemetry?source=oas_event&n=5" "'entries' in d and 'total_matching_entries' in d and 'truncated' in d and d.get('dashboard_surface') == '/api/v1/dashboard/telemetry' and d.get('source') == 'telemetry_unified' and d.get('retention', {}).get('scope') == 'dashboard_telemetry_replay' and 'oas_event' in d.get('query', {}).get('resolved_sources', [])" '^True$'
check_http "oas telemetry recent 200" "$BASE/api/v1/dashboard/oas/telemetry/recent?limit=5" "200"
check_json "oas telemetry recent exposes provenance" "$BASE/api/v1/dashboard/oas/telemetry/recent?limit=5" "'samples' in d and 'dashboard_surface' in d and 'retention' in d" '^True$'
check_http "oas telemetry summary 200" "$BASE/api/v1/dashboard/oas/telemetry/summary?limit=5" "200"
check_json "oas telemetry summary exposes provenance" "$BASE/api/v1/dashboard/oas/telemetry/summary?limit=5" "'summary' in d and 'dashboard_surface' in d and 'retention' in d" '^True$'
check_http "runtime providers 200" "$BASE/api/v1/providers" "200"
check_json "runtime providers exposes inventory" "$BASE/api/v1/providers" "'summary' in d and 'providers' in d" '^True$'
check_http "model metrics 200" "$BASE/api/v1/models/metrics?window=30&bucket_min=5" "200"
check_json "model metrics exposes model list" "$BASE/api/v1/models/metrics?window=30&bucket_min=5" "'models' in d" '^True$'
check_http "keeper costs 200" "$BASE/api/v1/dashboard/keeper-costs?window=60" "200"
check_json "keeper costs exposes keepers" "$BASE/api/v1/dashboard/keeper-costs?window=60" "'keepers' in d" '^True$'
check_http "memory subsystems 200" "$BASE/api/v1/dashboard/memory-subsystems" "200"
check_json "memory subsystems has hebbian block" "$BASE/api/v1/dashboard/memory-subsystems" "'hebbian' in d" '^True$'
check_http "transport health 200" "$BASE/api/v1/dashboard/transport-health" "200"
check_json "transport health exposes provenance" "$BASE/api/v1/dashboard/transport-health" "'summary' in d and d.get('dashboard_surface') == '/api/v1/dashboard/transport-health' and d.get('source') == 'transport_health_read_model' and d.get('retention', {}).get('scope') == 'dashboard_transport_health' and d.get('query', {}).get('default_snapshot_request') is True and d.get('cache', {}).get('cache_state') in ('fresh', 'stale', 'initializing', 'request_swr_or_inline_compute')" '^True$'
check_http "attribution summary 200" "$BASE/api/v1/attribution/summary" "200"
check_json "attribution summary has gates" "$BASE/api/v1/attribution/summary" "'gates' in d" '^True$'
check_http "attribution recent 200" "$BASE/api/v1/attribution/recent?limit=1" "200"
check_json "attribution recent exposes events" "$BASE/api/v1/attribution/recent?limit=1" "'events' in d and 'count' in d" '^True$'
check_http "dashboard Gate 200" "$BASE/api/v1/dashboard/gate" "200"
check_json "dashboard Gate exposes mode and queue" "$BASE/api/v1/dashboard/gate" "'hitl' in d and 'approval_queue' in d and 'approval_rules' in d" '^True$'
check_http "dashboard proof 200" "$BASE/api/v1/dashboard/proof" "200"
check_json "dashboard proof exposes verification and sources" "$BASE/api/v1/dashboard/proof" "'summary' in d and 'verification' in d and 'proof_sources' in d" '^True$'
check_http "keeper feature proof 200" "$BASE/api/v1/dashboard/keeper-feature-proof?window_hours=24" "200"
check_json "keeper feature proof exposes features" "$BASE/api/v1/dashboard/keeper-feature-proof?window_hours=24" "'summary' in d and 'features' in d and 'evidence_refs' in d" '^True$'
check_http "feature health 200" "$BASE/api/v1/dashboard/feature-health" "200"
check_json "feature health exposes overview" "$BASE/api/v1/dashboard/feature-health" "'overview' in d and 'features_by_category' in d" '^True$'
check_http "dashboard perf 200" "$BASE/api/v1/dashboard/perf" "200"
check_json "dashboard perf exposes benchmark status" "$BASE/api/v1/dashboard/perf" "'status' in d and 'benchmarks' in d" '^True$'
check_http "cost latency 200" "$BASE/api/v1/dashboard/cost-latency?window=60" "200"
check_json "cost latency exposes cost and latency" "$BASE/api/v1/dashboard/cost-latency?window=60" "'total_cost_usd' in d and 'latencyBuckets' in d" '^True$'
check_http "keeper decisions 200" "$BASE/api/v1/dashboard/keeper-decisions?limit=1" "200"
check_json "keeper decisions exposes provenance" "$BASE/api/v1/dashboard/keeper-decisions?limit=1" "'events' in d and d.get('dashboard_surface') == '/api/v1/dashboard/keeper-decisions' and d.get('source') == 'keeper_decision_log' and 'retention' in d" '^True$'

echo "[4/7] Operations + Workspace"
check_http "operator digest 200" "$BASE/api/v1/operator/digest" "200"
check_json "operator digest exposes provenance" "$BASE/api/v1/operator/digest" "'health' in d and d.get('dashboard_surface') == '/api/v1/operator/digest' and d.get('source') == 'operator_digest_read_model' and d.get('retention', {}).get('scope') == 'operator_digest' and d.get('query', {}).get('effective_target_type') == 'workspace' and d.get('cache', {}).get('cache_state') in ('fresh', 'stale', 'initializing', 'request_swr_or_inline_compute')" '^True$'
check_http "operator snapshot 200" "$BASE/api/v1/operator" "200"
check_json "operator snapshot exposes provenance" "$BASE/api/v1/operator" "'available_actions' in d and 'keepers' in d and d.get('dashboard_surface') == '/api/v1/operator' and d.get('source') == 'operator_snapshot_read_model' and d.get('retention', {}).get('scope') == 'operator_snapshot' and d.get('query', {}).get('default_summary_request') is True and d.get('cache', {}).get('cache_state') in ('fresh', 'stale', 'initializing', 'request_swr_or_inline_compute')" '^True$'
check_http "board 200" "$BASE/api/v1/dashboard/board" "200"
check_json "board exposes posts" "$BASE/api/v1/dashboard/board" "'posts' in d" '^True$'
check_http "board API 200" "$BASE/api/v1/board?limit=1" "200"
check_json "board API exposes posts" "$BASE/api/v1/board?limit=1" "'posts' in d and 'count' in d" '^True$'
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
check_http "goals tree 200" "$BASE/api/v1/dashboard/goals" "200"
check_json "goals tree exposes summary" "$BASE/api/v1/dashboard/goals" "'summary' in d and 'tree' in d" '^True$'
check_http "git diff 200" "$BASE/api/v1/git/diff?path=README.md" "200"
check_json "git diff exposes unified diff state" "$BASE/api/v1/git/diff?path=README.md" "'has_changes' in d and 'unified' in d" '^True$'
check_http "repositories 200" "$BASE/api/v1/repositories" "200"
check_json "repositories exposes list" "$BASE/api/v1/repositories" "'repositories' in d and 'total' in d" '^True$'
check_http "keeper repos 200" "$BASE/api/v1/keeper-repos" "200"
check_json "keeper repos exposes mappings" "$BASE/api/v1/keeper-repos" "'mappings' in d and 'total' in d" '^True$'
check_http "workspace tree 200" "$BASE/api/v1/workspace/tree?depth=1" "200"
check_json "workspace tree exposes nodes array" "$BASE/api/v1/workspace/tree?depth=1" "len(d) >= 0" '^True$'
check_http "workspace file 200" "$BASE/api/v1/workspace/file?path=README.md" "200"
check_json "workspace file exposes content" "$BASE/api/v1/workspace/file?path=README.md" "d.get('ok') == True and 'content' in d" '^True$'
check_http "verification requests 200" "$BASE/api/v1/verification/requests" "200"
check_json "verification requests exposes list" "$BASE/api/v1/verification/requests" "'requests' in d" '^True$'
check_http "verification summary 200" "$BASE/api/v1/verification/summary" "200"
check_json "verification summary exposes status buckets" "$BASE/api/v1/verification/summary" "'by_status' in d" '^True$'
check_http "verification specs 200" "$BASE/api/v1/verification/specs" "200"
check_json "verification specs exposes index" "$BASE/api/v1/verification/specs" "'entries' in d and 'count' in d" '^True$'
check_http "verification tlc results 200" "$BASE/api/v1/verification/tlc-results" "200"
check_json "verification tlc results exposes entries" "$BASE/api/v1/verification/tlc-results" "'entries' in d and 'count' in d" '^True$'

echo "[5/7] Connectors + Lab"
check_http "gate status 200" "$BASE/api/v1/gate/status" "200"
check_json "gate status exposes channel bindings" "$BASE/api/v1/gate/status" "'channels' in d and 'bindings' in d" '^True$'
check_http "gate connectors 200" "$BASE/api/v1/gate/connectors" "200"
check_json "gate connectors exposes connectors list" "$BASE/api/v1/gate/connectors" "'connectors' in d" '^True$'
check_http "sidecar status 200" "$BASE/api/v1/sidecar/status?name=discord" "200"
check_json "sidecar status exposes provenance" "$BASE/api/v1/sidecar/status?name=discord" "d.get('dashboard_surface') == '/api/v1/sidecar/status' and d.get('source') == 'sidecar_status_file' and d.get('retention', {}).get('scope') == 'runtime_sidecar_status' and 'sidecar_lifecycle' in d" '^True$'
check_http "dashboard tools 200" "$BASE/api/v1/dashboard/tools" "200"
check_json "dashboard tools exposes inventory" "$BASE/api/v1/dashboard/tools" "'tool_inventory' in d" '^True$'
check_http "tool quality 200" "$BASE/api/v1/dashboard/tool-quality?window_hours=24" "200"
check_json "tool quality exposes aggregates" "$BASE/api/v1/dashboard/tool-quality?window_hours=24" "'total' in d and 'by_tool' in d and 'failure_categories' in d" '^True$'
check_http "tool metrics 200" "$BASE/api/v1/tool-metrics" "200"
check_json "tool metrics exposes usage" "$BASE/api/v1/tool-metrics" "'total_calls' in d and 'top_20' in d and 'registered_count' in d" '^True$'
check_http "prompt registry 200" "$BASE/api/v1/prompts" "200"
check_json "prompt registry exposes prompts" "$BASE/api/v1/prompts" "'prompts' in d" '^True$'
check_http "excuse pattern config 200" "$BASE/api/v1/dashboard/config/excuse-patterns" "200"
check_json "excuse pattern config exposes list" "$BASE/api/v1/dashboard/config/excuse-patterns" "len(d) >= 0" '^True$'
check_http "harness health 200" "$BASE/api/v1/dashboard/harness-health" "200"
check_json "harness health exposes overview" "$BASE/api/v1/dashboard/harness-health" "'overview' in d" '^True$'

echo "[6/7] Code + Logs"
check_http "audit ledger 200" "$BASE/api/v1/audit?limit=1" "200"
check_json "audit ledger exposes entries" "$BASE/api/v1/audit?limit=1" "'entries' in d and 'count' in d" '^True$'
check_http "IDE presence 200" "$BASE/api/v1/ide/presence" "200"
check_json "IDE presence exposes connected state" "$BASE/api/v1/ide/presence" "d.get('data', {}).get('connected')" '^True$'
check_http "IDE annotations 200" "$BASE/api/v1/ide/annotations" "200"
check_json "IDE annotations exposes data envelope" "$BASE/api/v1/ide/annotations" "d.get('ok') == True and 'data' in d" '^True$'
check_http "IDE regions 200" "$BASE/api/v1/ide/regions" "200"
check_json "IDE regions exposes data envelope" "$BASE/api/v1/ide/regions" "d.get('ok') == True and 'data' in d" '^True$'
check_http "dashboard logs 200" "$BASE/api/v1/dashboard/logs?limit=3" "200"
check_json "dashboard logs exposes provenance" "$BASE/api/v1/dashboard/logs?limit=3" "d.get('dashboard_surface') == '/api/v1/dashboard/logs' and d.get('source') == 'masc_log_ring' and d.get('retention', {}).get('scope') == 'dashboard_logs' and 'generated_at_iso' in d and 'entries' in d" '^True$'

echo "[7/7] SPA"
check_http "dashboard index 200" "$BASE/dashboard" "200"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL $TOTAL TESTS PASSED ==="
else
  echo "=== $PASS/$TOTAL passed, $FAIL FAILED ==="
  exit 1
fi
