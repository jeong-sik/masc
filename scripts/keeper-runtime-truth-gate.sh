#!/usr/bin/env bash
# keeper-runtime-truth-gate.sh - read-only proof gate for one keeper turn.
#
# Validates that a persisted keeper turn has a runtime manifest, receipt link,
# checkpoint link, provider-lane decision fields, and optional runtime-trace API
# coverage. It does not start keepers or mutate live runtime state.
#
# Usage:
#   scripts/keeper-runtime-truth-gate.sh --base-path ~/me --keeper sangsu
#   scripts/keeper-runtime-truth-gate.sh --base-path ~/me --keeper sangsu \
#     --trace-id trace-... --turn-id 42 --server-url http://127.0.0.1:8931
#   scripts/keeper-runtime-truth-gate.sh --self-test

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-${ME_ROOT:-$HOME/me}}"
KEEPER=""
TRACE_ID=""
TURN_ID=""
MODE="provider"
SERVER_URL=""
LIMIT=200
REQUIRE_TOOL_CALL=0
SELF_TEST=0

usage() {
  sed -n '2,/^$/p' "$0"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

log() {
  printf '[runtime-truth-gate] %s\n' "$*" >&2
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --keeper) KEEPER="$2"; shift 2 ;;
    --trace-id) TRACE_ID="$2"; shift 2 ;;
    --turn-id) TURN_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --server-url) SERVER_URL="${2%/}"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --require-tool-call) REQUIRE_TOOL_CALL=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage; exit 64 ;;
  esac
done

command -v jq >/dev/null || fail "jq required"

if [[ "$SELF_TEST" = "1" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/keeper-runtime-truth-gate.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  keeper="runtime-truth-gate"
  trace="trace-self-test"
  turn="7"
  keeper_dir="$tmp/.masc/keepers/$keeper"
  manifest_dir="$keeper_dir/runtime-manifests"
  receipt_dir="$keeper_dir/execution-receipts/2026-05"
  checkpoint_dir="$keeper_dir/checkpoints"
  tool_log_dir="$tmp/.masc/tool_calls/2026-05"
  mkdir -p "$manifest_dir" "$receipt_dir" "$checkpoint_dir" "$tool_log_dir"
  receipt_path="$receipt_dir/12.jsonl"
  checkpoint_path="$checkpoint_dir/state-snapshot.latest.json"
  tool_log_path="$tool_log_dir/12.jsonl"
  printf '{"ok":true}\n' >"$checkpoint_path"
  printf '{"keeper":"%s","trace_id":"%s","tool":"keeper_tool_search","success":true}\n' \
    "$keeper" "$trace" >"$tool_log_path"
  printf '{"schema":"keeper.execution_receipt.v1","keeper_name":"%s","trace_id":"%s","turn_count":%s,"outcome":"success","tools_used":["keeper_tool_search"]}\n' \
    "$keeper" "$trace" "$turn" >"$receipt_path"
  manifest_path="$manifest_dir/$trace.jsonl"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:00Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"checkpoint_loaded",cascade_name:null,provider_kind:null,model_id:null,status:"ok",decision:{},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:01Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"provider_lane_resolved",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"resolved",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false,requested_tool_names:["keeper_tool_search"],required_tool_names:["keeper_tool_search"],materialized_tool_names:["keeper_tool_search"],missing_required_tool_names_after_lane:[],resolved_lane:"inline"},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:02Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"provider_attempt_started",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"started",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:03Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:2,event:"provider_attempt_finished",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"provider_returned",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --arg p "$checkpoint_path" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:04Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"checkpoint_saved",cascade_name:null,provider_kind:null,model_id:null,status:"ok",decision:{},links:{receipt_path:null,checkpoint_path:$p,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --arg p "$receipt_path" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:05Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"receipt_appended",cascade_name:null,provider_kind:null,model_id:null,status:"ok",decision:{},links:{receipt_path:$p,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:06Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"event_bus_correlated",cascade_name:null,provider_kind:null,model_id:null,status:"observed",decision:{correlation_id:"corr-self-test",run_id:"run-self-test",caused_by:null,overflow_imminent:null,context_compact_started_count:0,context_compacted_count:0,last_compaction:null},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:07Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:1,event:"memory_injected",cascade_name:null,provider_kind:null,model_id:null,status:"skipped",decision:{memory_context_present:false,episode_limit:30,procedure_limit:10,existing_extra_system_context_present:false,existing_extra_system_context_chars:0},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:08Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:1,event:"memory_flushed",cascade_name:null,provider_kind:null,model_id:null,status:"success",decision:{episodes_flushed:0,procedures_flushed:0,duration_s:0.0,response_model:"fixture-model"},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$manifest_path"
  jq -cn --arg k "$keeper" --arg t "$trace" --arg p "$tool_log_path" --argjson turn "$turn" \
    '{schema_version:1,ts:"2026-05-12T00:00:09Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"turn_finished",cascade_name:null,provider_kind:null,model_id:null,status:"success",decision:{},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:$p}}' >>"$manifest_path"
  "$0" --base-path "$tmp" --keeper "$keeper" --trace-id "$trace" \
    --turn-id "$turn" --mode provider --require-tool-call
  fail_keeper="runtime-truth-gate-timeout"
  fail_trace="trace-self-test-timeout"
  fail_turn="8"
  fail_keeper_dir="$tmp/.masc/keepers/$fail_keeper"
  fail_manifest_dir="$fail_keeper_dir/runtime-manifests"
  fail_receipt_dir="$fail_keeper_dir/execution-receipts/2026-05"
  mkdir -p "$fail_manifest_dir" "$fail_receipt_dir"
  fail_receipt_path="$fail_receipt_dir/12.jsonl"
  printf '{"schema":"keeper.execution_receipt.v1","keeper_name":"%s","trace_id":"%s","turn_count":%s,"outcome":"error","error_kind":"api_error_timeout","tools_used":[]}\n' \
    "$fail_keeper" "$fail_trace" "$fail_turn" >"$fail_receipt_path"
  fail_manifest_path="$fail_manifest_dir/$fail_trace.jsonl"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:00Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"provider_lane_resolved",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"resolved",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false,requested_tool_names:[],required_tool_names:[],materialized_tool_names:[],missing_required_tool_names_after_lane:[],resolved_lane:"inline"},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:01Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"provider_attempt_started",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"started",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:02Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"provider_attempt_finished",cascade_name:"fixture",provider_kind:"openai",model_id:"fixture-model",status:"timeout",decision:{cascade_engine:"masc_keeper_named_cascade",oas_dispatch_mode:"single_provider_agent_run",oas_internal_cascade_allowed:false,exception_kind:"outer_oas_timeout",error:"Timeout after 120.0s"},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:04Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:0,event:"memory_injected",cascade_name:null,provider_kind:null,model_id:null,status:"skipped",decision:{memory_context_present:false,episode_limit:30,procedure_limit:10},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --arg p "$fail_receipt_path" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:05Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"receipt_appended",cascade_name:null,provider_kind:null,model_id:null,status:"ok",decision:{},links:{receipt_path:$p,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  jq -cn --arg k "$fail_keeper" --arg t "$fail_trace" --argjson turn "$fail_turn" \
    '{schema_version:1,ts:"2026-05-12T00:01:06Z",keeper_name:$k,agent_name:null,trace_id:$t,generation:1,keeper_turn_id:$turn,oas_turn_count:null,event:"turn_finished",cascade_name:null,provider_kind:null,model_id:null,status:"error",decision:{terminal_reason_code:"api_error_timeout"},links:{receipt_path:null,checkpoint_path:null,tool_call_log_path:null}}' >>"$fail_manifest_path"
  "$0" --base-path "$tmp" --keeper "$fail_keeper" --trace-id "$fail_trace" \
    --turn-id "$fail_turn" --mode provider
  exit 0
fi

case "$MODE" in
  any|provider) ;;
  *) fail "--mode must be 'any' or 'provider'" ;;
esac

[[ -n "$KEEPER" ]] || fail "--keeper required"

KEEPER_DIR="$BASE_PATH/.masc/keepers/$KEEPER"
MANIFEST_DIR="$KEEPER_DIR/runtime-manifests"
[[ -d "$MANIFEST_DIR" ]] || fail "runtime manifest directory missing: $MANIFEST_DIR"

if [[ -z "$TRACE_ID" ]]; then
  manifest_candidates=()
  while IFS= read -r -d '' candidate; do
    manifest_candidates+=("$candidate")
  done < <(find "$MANIFEST_DIR" -type f -name '*.jsonl' -print0)
  [[ ${#manifest_candidates[@]} -gt 0 ]] || fail "no runtime manifest JSONL files under $MANIFEST_DIR"
  latest_manifest="${manifest_candidates[0]}"
  for candidate in "${manifest_candidates[@]}"; do
    if [[ "$candidate" -nt "$latest_manifest" ]]; then
      latest_manifest="$candidate"
    fi
  done
  TRACE_ID="$(basename "$latest_manifest" .jsonl)"
else
  latest_manifest="$MANIFEST_DIR/$TRACE_ID.jsonl"
fi

[[ -f "$latest_manifest" ]] || fail "manifest file missing: $latest_manifest"

if [[ -z "$TURN_ID" ]]; then
  TURN_ID="$(jq -sr '[ .[] | .keeper_turn_id | select(. != null) ] | last // empty' "$latest_manifest")"
  [[ -n "$TURN_ID" ]] || fail "turn id not supplied and no keeper_turn_id found in $latest_manifest"
fi

turn_rows="$(jq -c --argjson turn "$TURN_ID" \
  'select(.keeper_turn_id == $turn or (.keeper_turn_id == null and .event == "turn_finished"))' \
  "$latest_manifest")"
[[ -n "$turn_rows" ]] || fail "no manifest rows for turn_id=$TURN_ID in $latest_manifest"

event_count="$(printf '%s\n' "$turn_rows" | jq -s 'length')"
log "base_path=$BASE_PATH keeper=$KEEPER trace_id=$TRACE_ID turn_id=$TURN_ID manifest_rows=$event_count"

turn_finished_status="$(printf '%s\n' "$turn_rows" | jq -r '
  select(.event == "turn_finished")
  | .status // empty
' | tail -n1)"
turn_finished_status="${turn_finished_status:-unknown}"

has_event() {
  local event="$1"
  printf '%s\n' "$turn_rows" | jq -e --arg event "$event" 'select(.event == $event)' >/dev/null
}

require_event() {
  local event="$1"
  has_event "$event" || fail "missing manifest event: $event"
}

require_event "receipt_appended"
require_event "turn_finished"

if [[ "$MODE" = "provider" ]]; then
  require_event "provider_lane_resolved"
  require_event "provider_attempt_started"
  require_event "provider_attempt_finished"
  require_event "memory_injected"

  attempt_started_count="$(printf '%s\n' "$turn_rows" | jq -s '
    [ .[] | select(.event == "provider_attempt_started") ] | length
  ')"
  attempt_finished_count="$(printf '%s\n' "$turn_rows" | jq -s '
    [ .[] | select(.event == "provider_attempt_finished") ] | length
  ')"
  [[ "$attempt_finished_count" -ge "$attempt_started_count" ]] \
    || fail "provider attempts are not terminal: started=$attempt_started_count finished=$attempt_finished_count"

  if ! has_event "checkpoint_saved"; then
    [[ "$turn_finished_status" = "error" ]] \
      || fail "missing manifest event: checkpoint_saved"
    log "checkpoint_saved absent for terminal error turn; accepting rollback/no-checkpoint path"
  fi

  if ! has_event "event_bus_correlated"; then
    [[ "$turn_finished_status" = "error" ]] \
      || fail "missing manifest event: event_bus_correlated"
    log "event_bus_correlated absent for terminal error turn; accepting pre-correlation failure path"
  fi

  if has_event "event_bus_correlated"; then
    printf '%s\n' "$turn_rows" | jq -e '
      select(.event == "event_bus_correlated")
      | (.decision.correlation_id == null or (.decision.correlation_id | type == "string"))
        and (.decision.run_id == null or (.decision.run_id | type == "string"))
        and (.decision.context_compact_started_count | type == "number")
        and (.decision.context_compacted_count | type == "number")
    ' >/dev/null || fail "event_bus_correlated is missing OAS event-bus summary fields"
  fi

  printf '%s\n' "$turn_rows" | jq -e '
    select(.event == "memory_injected")
    | (.decision.memory_context_present | type == "boolean")
      and (.decision.episode_limit | type == "number")
      and (.decision.procedure_limit | type == "number")
  ' >/dev/null || fail "memory_injected is missing memory injection summary fields"

  printf '%s\n' "$turn_rows" | jq -e '
    select(.event == "provider_lane_resolved")
    | .decision.cascade_engine == "masc_keeper_named_cascade"
      and .decision.oas_dispatch_mode == "single_provider_agent_run"
      and .decision.oas_internal_cascade_allowed == false
      and (.decision.materialized_tool_names | type == "array")
      and (.decision.missing_required_tool_names_after_lane | type == "array")
  ' >/dev/null || fail "provider_lane_resolved is missing keeper/OAS boundary or lane fields"
fi

receipt_path="$(printf '%s\n' "$turn_rows" | jq -r '
  select(.event == "receipt_appended")
  | .links.receipt_path // empty
' | tail -n1)"
[[ -n "$receipt_path" ]] || fail "receipt_appended row lacks links.receipt_path"
[[ -f "$receipt_path" ]] || fail "linked receipt path missing: $receipt_path"

checkpoint_path="$(printf '%s\n' "$turn_rows" | jq -r '
  select(.event == "checkpoint_saved")
  | .links.checkpoint_path // empty
' | tail -n1)"
if [[ "$MODE" = "provider" ]]; then
  if has_event "checkpoint_saved"; then
    [[ -n "$checkpoint_path" ]] || fail "checkpoint_saved row lacks links.checkpoint_path"
    [[ -f "$checkpoint_path" ]] || fail "linked checkpoint path missing: $checkpoint_path"
  else
    checkpoint_path=""
  fi
fi

receipt_match="$(jq -sr --arg trace "$TRACE_ID" --argjson turn "$TURN_ID" '
  [ .[] | select((.trace_id // "") == $trace or (.turn_count // null) == $turn) ]
  | length
' "$receipt_path")"
[[ "$receipt_match" -gt 0 ]] || fail "linked receipt does not contain trace_id=$TRACE_ID or turn_count=$TURN_ID"

tools_used_count="$(jq -sr '
  [ .[] | (.tools_used // [])[]? ] | length
' "$receipt_path")"

tool_log_path="$(printf '%s\n' "$turn_rows" | jq -r '
  select(.event == "turn_finished")
  | .links.tool_call_log_path // empty
' | tail -n1)"

if [[ "$REQUIRE_TOOL_CALL" = "1" || "$tools_used_count" -gt 0 ]]; then
  [[ -n "$tool_log_path" ]] || fail "tool use was present/required but turn_finished lacks tool_call_log_path"
  [[ -f "$tool_log_path" ]] || fail "linked tool-call log path missing: $tool_log_path"
fi

if [[ -n "$SERVER_URL" ]]; then
  keeper_enc="$(urlencode "$KEEPER")"
  trace_enc="$(urlencode "$TRACE_ID")"
  api_url="$SERVER_URL/api/v1/keepers/$keeper_enc/runtime-trace?trace_id=$trace_enc&turn_id=$TURN_ID&limit=$LIMIT"
  api_json="$(curl -fsS --max-time 10 "$api_url")" || fail "runtime-trace API request failed: $api_url"
  printf '%s' "$api_json" | jq -e --arg trace "$TRACE_ID" --argjson turn "$TURN_ID" '
    .trace_id == $trace
    and (.turn_id == $turn or .turn_id == null)
    and (.manifest_total_rows // 0) > 0
    and ((.manifest_rows // []) | length) > 0
	    and ((.linked_artifacts.receipts // []) | length) > 0
	    and ((.turn_identity.manifest_keeper_turn_ids // []) | index($turn) != null)
	    and ((.turn_identity.memory_injected_count // 0) > 0)
	    and ((.memory.memory_injected_count // 0) > 0)
	    and ((.turn_identity.receipt_appended_count // 0) > 0)
	  ' >/dev/null || fail "runtime-trace API response does not cover manifest/receipt chain"
  log "runtime-trace API ok: $api_url"
fi

cat <<EOF
keeper-runtime-truth-gate: PASS
  base_path: $BASE_PATH
  keeper: $KEEPER
  trace_id: $TRACE_ID
  turn_id: $TURN_ID
  mode: $MODE
  manifest_path: $latest_manifest
  manifest_rows_checked: $event_count
  receipt_path: $receipt_path
  checkpoint_path: ${checkpoint_path:-none}
  tool_call_log_path: ${tool_log_path:-none}
EOF
