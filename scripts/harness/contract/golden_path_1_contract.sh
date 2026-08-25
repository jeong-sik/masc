#!/usr/bin/env bash
# Golden Path 1 Contract — Strict workspace collaboration e2e verification.
#
# Tests the fundamental 10-step external MCP workflow:
#   producer join → add_task → claim → plan_set_task → heartbeat → broadcast
#   → status → direct-done rejection → submit_for_verification
#   → post-submission producer projection
#
# This is the opt-in strict verification path. Advisory/default task completion
# remains direct and is covered by the workspace and Keeper outcome suites.
#
# Usage:
#   MCP_URL=http://127.0.0.1:8935/mcp MCP_TOKEN=... ./golden_path_1_contract.sh
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
    call_tool 1999 "masc_transition" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,action:"cancel",notes:"GP1 contract cleanup after unsuccessful run"}')" >/dev/null 2>&1 || true
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

  goal_payload="$(call_tool 1000 "masc_goal_upsert" '{"title":"GP1 contract goal","metric":"contract steps pass","target_value":"all steps","priority":1}')"
  goal_json="$(printf '%s' "$goal_payload" | extract_result)"
  GOAL_ID="$(printf '%s' "$goal_json" | jq -r '.goal_id // empty')"
  if [ -z "$GOAL_ID" ]; then
    mcp_fail_with_context "could not create goal for contract goal_id" "$goal_payload"
  fi
}

step_pass() { PASS=$((PASS + 1)); echo "  PASS"; }
step_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ── Step 1/10: start / bind producer session ──
echo "[1/10] masc_start (producer)"
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

# ── Step 2/10: add_task ──
echo "[2/10] masc_add_task"
task_title="GP1 contract task $(date +%s)"
r2="$(call_tool 1002 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" --arg task_title "$task_title" '{title: $task_title, goal_id: $goal_id, priority: 2, description: "Automated strict golden path contract verification", contract:{strict:true,completion_contract:["distinct verifier approval"]}}')")"
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

# ── Step 3/10: claim ──
echo "[3/10] masc_transition (producer claim)"
r3="$(call_tool 1003 "masc_transition" "{\"task_id\":\"$task_id\",\"action\":\"claim\",\"notes\":\"GP1 contract claim\"}")"
if require_ok "$r3"; then
  step_pass
else
  step_fail "claim failed"
  echo "$r3"
  exit 1
fi

# ── Step 4/10: plan_set_task ──
echo "[4/10] masc_plan_set_task"
r4="$(call_tool 1004 "masc_plan_set_task" "{\"task_id\":\"$task_id\"}")"
if require_ok "$r4"; then
  step_pass
else
  step_fail "plan_set_task failed"
  echo "$r4"
fi

# ── Step 5/10: heartbeat ──
echo "[5/10] masc_heartbeat"
r5="$(call_tool 1005 "masc_heartbeat" "{}")"
if require_ok "$r5"; then
  step_pass
else
  step_fail "heartbeat failed"
  echo "$r5"
fi

# ── Step 6/10: broadcast ──
echo "[6/10] masc_broadcast"
r6="$(call_tool 1006 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg content "GP1 contract verification in progress" '{agent_name:$agent_name,content:$content}')")"
if require_ok "$r6"; then
  step_pass
else
  step_fail "broadcast failed"
  echo "$r6"
fi

# ── Step 7/10: status ──
echo "[7/10] masc_status"
r7="$(call_tool 1007 "masc_status" "{}")"
if require_ok "$r7"; then
  step_pass
else
  step_fail "status failed"
  echo "$r7"
fi

evidence_ref="note:GP1 contract live MCP transcript verified by producer ${AGENT_NAME}"
done_notes="Completed GP1 contract flow: bound workspace, created and claimed task, set current task, sent heartbeat, broadcast progress, and verified masc_status returned success."
done_summary="GP1 contract flow verified end to end via live MCP transcript"

# ── Step 8/10: producer cannot bypass verification with direct done ──
echo "[8/10] masc_transition (direct done rejection)"
r8="$(call_tool 1008 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg notes "$done_notes" --arg summary "$done_summary" --arg evidence_ref "$evidence_ref" '{task_id:$task_id,action:"done",notes:$notes,handoff_context:{summary:$summary,evidence_refs:[$evidence_ref]}}')")"
if require_ok "$r8" >/dev/null 2>&1; then
  step_fail "direct done unexpectedly succeeded"
  echo "$r8"
elif [[ "$r8" == *"Task completion must be submitted for verification"* ]] \
  && [[ "$r8" != *"Configured LLM completion verifier"* ]]; then
  step_pass
else
  step_fail "direct done did not return Verification_submission_required"
  echo "$r8"
fi

# ── Step 9/10: producer submits typed evidence for verification ──
echo "[9/10] masc_transition (submit_for_verification)"
r9="$(call_tool 1009 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg notes "$done_notes" --arg summary "$done_summary" --arg evidence_ref "$evidence_ref" '{task_id:$task_id,action:"submit_for_verification",notes:$notes,handoff_context:{summary:$summary,evidence_refs:[$evidence_ref]}}')")"
if require_ok "$r9"; then
  step_pass
else
  step_fail "submit_for_verification failed"
  echo "$r9"
fi

# ── Step 10/10: submission remains credited to its producer ──
# The application-owned authority may reject before this query runs, returning
# the task to in_progress. Both states must retain the submitting producer.
echo "[10/10] masc_tasks (post-submission producer credit)"
r10="$(call_tool 1010 "masc_tasks" '{}')"
if require_ok "$r10" \
  && [[ "$r10" == *"$task_id"* ]] \
  && { [[ "$r10" == *"awaiting_verification"* ]] || [[ "$r10" == *"in_progress"* ]]; } \
  && [[ "$r10" == *"$AGENT_NAME"* ]]; then
  # Submission is not terminal. Keep EXIT cleanup armed so a verifier rejection
  # cannot leak this producer-owned task into the next contract scenario.
  step_pass
else
  step_fail "post-submission projection did not retain producer credit"
  echo "$r10"
fi

# ── Summary ──
echo ""
echo "=== Golden Path 1 Contract ==="
echo "  PASS: $PASS / 10"
echo "  FAIL: $FAIL / 10"
if [ "$FAIL" -gt 0 ]; then
  echo "  STATUS: BROKEN"
  exit 1
else
  echo "  STATUS: GREEN"
  exit 0
fi
