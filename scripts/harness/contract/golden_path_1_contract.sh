#!/usr/bin/env bash
# Golden Path 1 Contract — Core workspace collaboration e2e verification.
#
# Tests the fundamental 8-step MASC workflow:
#   join → add_task → claim → plan_set_task → heartbeat → broadcast → status → done
#
# This is the minimum viable path that must always work.
# If this contract fails, MASC workspace collaboration is broken.
#
# Usage:
#   MCP_URL=http://127.0.0.1:8935/mcp ./golden_path_1_contract.sh
#   MCP_URL=http://127.0.0.1:9935/mcp ./golden_path_1_contract.sh  # dev instance
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-${MCP_AGENT_NAME:-golden-path-1-harness}}"
MCP_SESSION_ID="${MCP_SESSION_ID:-}"
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/test_framework.sh"

PASS=0
FAIL=0
GOAL_ID=""
CLEANUP_TASK_FINALIZED=0
START_PATH="${BASE_PATH:-$PWD}"

# shellcheck disable=SC2329 # invoked by EXIT trap
cleanup_contract_task() {
  local exit_status=$?
  if [ "$CLEANUP_TASK_FINALIZED" -ne 1 ] && [ -n "${task_id:-}" ]; then
    call_tool 1999 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"cancel",notes:"GP1 contract cleanup after unsuccessful run"}')" >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap 'cleanup_contract_task' EXIT

initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}
if [ -z "${MCP_SESSION_ID:-}" ]; then
  echo "FAIL: empty MCP_SESSION_ID after initialize" >&2
  exit 1
fi

ensure_contract_goal() {
  local goal_payload
  local goal_json

  goal_payload="$(call_tool 1000 "masc_goal_upsert" '{"title":"GP1 contract goal","priority":1}')"
  goal_json="$(printf '%s' "$goal_payload" | extract_result)"
  GOAL_ID="$(printf '%s' "$goal_json" | jq -r '.goal_id // empty')"
  if [ -z "$GOAL_ID" ]; then
    mcp_fail_with_context "could not create goal for contract goal_id" "$goal_payload"
  fi
}

step_pass() { PASS=$((PASS + 1)); echo "  PASS"; }
step_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ── Step 1/8: start / bind session ──
echo "[1/8] masc_start"
r1="$(call_tool 1001 "masc_start" "$(jq -cn --arg path "$START_PATH" '{path:$path}')")"
if require_ok "$r1"; then
  step_pass
else
  step_fail "masc_start rejected"
  echo "$r1"
  exit 1
fi
if [ -z "${MCP_SESSION_ID:-}" ]; then
  step_fail "empty MCP_SESSION_ID after masc_start"
  exit 1
fi

ensure_contract_goal

# ── Step 2/8: add_task ──
echo "[2/8] masc_add_task"
task_title="GP1 contract task $(date +%s)"
r2="$(call_tool 1002 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" --arg task_title "$task_title" '{title: $task_title, goal_id: $goal_id, priority: 2, description: "Automated golden path 1 contract verification"}')")"
if require_ok "$r2"; then
  step_pass
else
  step_fail "add_task failed"
  echo "$r2"
  exit 1
fi
task_json="$(printf '%s' "$r2" | extract_result)"
task_id="$(printf '%s' "$task_json" | jq -r '.task_id // .id // empty')"
if [ -z "$task_id" ]; then
  step_fail "could not extract task_id from add_task response"
  echo "$r2"
  exit 1
fi
echo "  task_id=$task_id"

# ── Step 3/8: claim ──
echo "[3/8] masc_transition (claim)"
r3="$(call_tool 1003 "masc_transition" "{\"task_id\":\"$task_id\",\"agent_name\":\"$AGENT_NAME\",\"action\":\"claim\",\"notes\":\"GP1 contract claim\"}")"
if require_ok "$r3"; then
  step_pass
else
  step_fail "claim failed"
  echo "$r3"
  exit 1
fi

# ── Step 4/8: plan_set_task ──
echo "[4/8] masc_plan_set_task"
r4="$(call_tool 1004 "masc_plan_set_task" "{\"task_id\":\"$task_id\"}")"
if require_ok "$r4"; then
  step_pass
else
  step_fail "plan_set_task failed"
  echo "$r4"
fi

# ── Step 5/8: heartbeat ──
echo "[5/8] masc_heartbeat"
r5="$(call_tool 1005 "masc_heartbeat" "{}")"
if require_ok "$r5"; then
  step_pass
else
  step_fail "heartbeat failed"
  echo "$r5"
fi

# ── Step 6/8: broadcast ──
echo "[6/8] masc_broadcast"
r6="$(call_tool 1006 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg message "GP1 contract verification in progress" '{agent_name:$agent_name,message:$message}')")"
if require_ok "$r6"; then
  step_pass
else
  step_fail "broadcast failed"
  echo "$r6"
fi

# ── Step 7/8: status ──
echo "[7/8] masc_status"
r7="$(call_tool 1007 "masc_status" "{}")"
if require_ok "$r7"; then
  step_pass
else
  step_fail "status failed"
  echo "$r7"
fi

# ── Step 8/8: done ──
echo "[8/8] masc_transition (done)"
# RFC-0311 Phase 1: the completion gate requires a trusted, reviewer-inspectable
# evidence_refs entry on done (notes alone no longer satisfy it). A trace ref
# naming this harness run is the appropriate evidence for a live MCP sweep.
done_notes="Completed GP1 contract flow: bound workspace, created and claimed task, set current task, sent heartbeat, broadcast progress, and verified masc_status returned success."
done_summary="GP1 contract flow verified end to end via live MCP transcript"
r8="$(call_tool 1008 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" --arg notes "$done_notes" --arg summary "$done_summary" '{task_id:$task_id,agent_name:$agent_name,action:"done",notes:$notes,handoff_context:{summary:$summary,evidence_refs:["trace:golden_path_1_contract"]}}')")"
if require_ok "$r8"; then
  CLEANUP_TASK_FINALIZED=1
  step_pass
else
  step_fail "done transition failed"
  echo "$r8"
fi

# ── Summary ──
echo ""
echo "=== Golden Path 1 Contract ==="
echo "  PASS: $PASS / 8"
echo "  FAIL: $FAIL / 8"
if [ "$FAIL" -gt 0 ]; then
  echo "  STATUS: BROKEN"
  exit 1
else
  echo "  STATUS: GREEN"
  exit 0
fi
