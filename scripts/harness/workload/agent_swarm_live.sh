#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PORT="${PORT:-8985}"
RUN_ID="${RUN_ID:-swarm-live-proof}"
MASC_URL="${MASC_URL:-http://127.0.0.1:${PORT}}"
MCP_URL="${MCP_URL:-${MASC_URL}/mcp}"
MCP_SESSION_ID="${MCP_SESSION_ID:-agent-swarm-live-${RUN_ID}-$$}"
BASE_PATH="${BASE_PATH:-/tmp/masc-agent-swarm-live-${RUN_ID}}"
PROVIDER_BASE_URL="${PROVIDER_BASE_URL:-http://127.0.0.1:3034}"
SLOT_URL="${SLOT_URL:-http://127.0.0.1:8085}"
MODEL_ID="${MODEL_ID:-qwen3.5-35b-a3b-ud-q8-xl}"
HARNESS_AGENT="${HARNESS_AGENT:-swarm-harness}"
WORKER_COUNT="${WORKER_COUNT:-12}"
MIN_HOT_SLOTS="${MIN_HOT_SLOTS:-10}"
REQUIRED_FINAL_MARKERS="${REQUIRED_FINAL_MARKERS:-$WORKER_COUNT}"
MAX_TURNS="${MAX_TURNS:-8}"
START_SERVER="${START_SERVER:-1}"
SLOT_SAMPLE_INTERVAL_SEC="${SLOT_SAMPLE_INTERVAL_SEC:-0.25}"
SERVER_PID=""
OPERATION_ID=""
HARNESS_PID=""
HARNESS_RESULT_FILE=""
SLOT_SAMPLER_PID=""
RUN_SLUG=""
RUN_ARTIFACT_DIR=""
SLOT_SAMPLES_FILE=""
SLOT_TELEMETRY_FILE=""
SWARM_SUMMARY_FILE=""
HARNESS_ARTIFACT_FILE=""

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

jsonrpc_call() {
  local id="$1"
  local method="$2"
  local params="$3"
  local raw
  raw="$(curl -sS -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":$params}")"
  local sse_data
  sse_data="$(printf "%s" "$raw" | sed -n 's/^data: //p')"
  if [ -n "$sse_data" ]; then
    local response_line
    response_line="$(
      printf "%s\n" "$sse_data" \
        | rg "\"id\"[[:space:]]*:[[:space:]]*$id([[:space:]],|[[:space:]]*})" \
        | tail -n1 || true
    )"
    if [ -n "$response_line" ]; then
      printf "%s" "$response_line"
    else
      echo "missing matching JSON-RPC response id: $id" >&2
      printf "%s\n" "$raw" >&2
      exit 1
    fi
  else
    printf "%s" "$raw"
  fi
}

call_tool() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  jsonrpc_call "$id" "tools/call" "{\"name\":\"$tool_name\",\"arguments\":$args_json}"
}

extract_result() {
  jq -c 'try (.result.content[0].text | fromjson | .result) catch empty'
}

extract_text() {
  jq -r 'try (.result.content[0].text) catch empty'
}

extract_is_error() {
  jq -r 'try (.result.isError) catch "true"'
}

require_tool_success() {
  local payload="$1"
  require_json "$payload"
  local is_error
  is_error="$(printf "%s" "$payload" | extract_is_error)"
  if [ "$is_error" = "true" ]; then
    printf "%s\n" "$payload" >&2
    echo "tool call failed" >&2
    exit 1
  fi
}

call_tool_checked() {
  local payload
  payload="$(call_tool "$@")"
  require_tool_success "$payload"
  printf "%s" "$payload"
}

extract_added_task_id() {
  local payload="$1"
  local text
  text="$(printf "%s" "$payload" | extract_text)"
  printf "%s\n" "$text" | sed -n 's/^✅ Added \(task-[0-9][0-9][0-9]\):.*$/\1/p' | head -n1
}

require_json() {
  local payload="$1"
  if ! printf "%s" "$payload" | jq -e . >/dev/null 2>&1; then
    echo "invalid payload" >&2
    printf "%s\n" "$payload" >&2
    exit 1
  fi
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"
  local delay="${3:-1}"
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  echo "timeout waiting for $url" >&2
  exit 1
}

slugify_run_id() {
  python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower().replace(".", "-")
value = re.sub(r"[^a-z0-9_-]+", "-", value)
value = re.sub(r"-{2,}", "-", value).strip("-")
print(value or "auto")
PY
}

resolve_swarm_live_root() {
  local legacy_root="$BASE_PATH/.masc/control-plane/swarm-live"
  local clusters_root="$BASE_PATH/.masc/clusters"
  if [ -d "$clusters_root" ]; then
    local first_cluster=""
    first_cluster="$(find "$clusters_root" -mindepth 1 -maxdepth 1 -type d | sort | head -n1)"
    if [ -n "$first_cluster" ] && [ -d "$first_cluster/control-plane" ]; then
      printf '%s\n' "$first_cluster/control-plane/swarm-live"
      return 0
    fi
  fi
  printf '%s\n' "$legacy_root"
}

start_slot_sampler() {
  : >"$SLOT_SAMPLES_FILE"
  (
    while true; do
      local ts payload sample
      ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      payload="$(curl -fsS "${SLOT_URL}/slots" 2>/dev/null || printf '[]')"
      sample="$(
        printf '%s' "$payload" \
          | jq -c --arg ts "$ts" '
              def active:
                ((.is_processing // false) == true)
                or (((.state // 0) | tonumber? // 0) != 0)
                or (((.status // "") | ascii_downcase) as $status | ($status == "processing" or $status == "prompt" or $status == "generating"));
              {
                timestamp: $ts,
                total_slots: length,
                active_slots: (map(select(active)) | length),
                active_slot_ids: (map(select(active) | (.id // .slot_id // .slot // -1))),
                ctx_per_slot: (map(.n_ctx // empty) | map(select(type == "number")) | if length > 0 then .[0] else null end)
              }'
      )"
      printf '%s\n' "$sample" >>"$SLOT_SAMPLES_FILE"
      sleep "$SLOT_SAMPLE_INTERVAL_SEC"
    done
  ) &
  SLOT_SAMPLER_PID="$!"
}

stop_slot_sampler() {
  if [ -n "$SLOT_SAMPLER_PID" ]; then
    kill "$SLOT_SAMPLER_PID" >/dev/null 2>&1 || true
    wait "$SLOT_SAMPLER_PID" >/dev/null 2>&1 || true
    SLOT_SAMPLER_PID=""
  fi
}

write_slot_telemetry() {
  local props_file
  props_file="$(mktemp /tmp/agent-swarm-live-props.XXXXXX.json)"
  curl -fsS "${SLOT_URL}/props" >"$props_file"
  python3 - "$SLOT_SAMPLES_FILE" "$props_file" "$SLOT_URL" "$MIN_HOT_SLOTS" "$SLOT_TELEMETRY_FILE" <<'PY'
import json
import sys
from pathlib import Path

samples_path = Path(sys.argv[1])
props_path = Path(sys.argv[2])
slot_url = sys.argv[3]
min_hot_slots = int(sys.argv[4])
output_path = Path(sys.argv[5])

samples = []
if samples_path.exists():
    for line in samples_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        samples.append(json.loads(line))

props = json.loads(props_path.read_text()) if props_path.exists() else {}
default_generation = props.get("default_generation_settings") or {}
active_counts = [int(sample.get("active_slots") or 0) for sample in samples]
peak_active_slots = max(active_counts) if active_counts else 0
samples_over_threshold = sum(1 for value in active_counts if value >= min_hot_slots)
timeline = [
    {
        "timestamp": sample.get("timestamp"),
        "active_slots": int(sample.get("active_slots") or 0),
        "active_slot_ids": sample.get("active_slot_ids") or [],
    }
    for sample in samples[-60:]
]

payload = {
    "slot_url": slot_url,
    "total_slots": int(props.get("total_slots") or 0),
    "ctx_per_slot": int(default_generation.get("n_ctx") or 0),
    "model_alias": props.get("model_alias"),
    "model_path": props.get("model_path"),
    "sample_count": len(samples),
    "active_slots_now": active_counts[-1] if active_counts else 0,
    "peak_active_slots": peak_active_slots,
    "samples_over_threshold": samples_over_threshold,
    "hot_window_ok": samples_over_threshold > 0,
    "last_sample_at": samples[-1].get("timestamp") if samples else None,
    "timeline": timeline,
}

output_path.write_text(json.dumps(payload, indent=2))
print(json.dumps(payload))
PY
  rm -f "$props_file"
}

write_harness_summary() {
  python3 - "$HARNESS_RESULT_FILE" "$SLOT_TELEMETRY_FILE" "$WORKER_COUNT" "$REQUIRED_FINAL_MARKERS" "$MIN_HOT_SLOTS" "$RUN_ID" "$SWARM_SUMMARY_FILE" <<'PY'
import json
import sys
from pathlib import Path

harness_path = Path(sys.argv[1])
slot_path = Path(sys.argv[2])
worker_count = int(sys.argv[3])
required_final_markers = int(sys.argv[4])
min_hot_slots = int(sys.argv[5])
run_id = sys.argv[6]
summary_path = Path(sys.argv[7])

harness = json.loads(harness_path.read_text())
slot = json.loads(slot_path.read_text()) if slot_path.exists() else {}
workers = harness.get("workers") or []
completed_workers = sum(1 for row in workers if row.get("status") == "ok")
final_markers_seen = sum(1 for row in workers if row.get("final_marker_seen") is True)
pass_hot_concurrency = int(slot.get("peak_active_slots") or 0) >= min_hot_slots and bool(slot.get("hot_window_ok"))
pass_end_to_end = completed_workers == worker_count and final_markers_seen >= required_final_markers

payload = {
    "run_id": run_id,
    "worker_count": worker_count,
    "min_hot_slots": min_hot_slots,
    "required_final_markers": required_final_markers,
    "completed_workers": completed_workers,
    "final_markers_seen": final_markers_seen,
    "pass_hot_concurrency": pass_hot_concurrency,
    "pass_end_to_end": pass_end_to_end,
    "pass": pass_hot_concurrency and pass_end_to_end,
}

summary_path.write_text(json.dumps(payload, indent=2))
print(json.dumps(payload))
PY
}

cleanup() {
  stop_slot_sampler
  if [ -n "$HARNESS_PID" ]; then
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$OPERATION_ID" ]; then
    call_tool 99090 "masc_operation_stop" \
      "$(jq -cn --arg operation_id "$OPERATION_ID" --arg note "harness cleanup after failure" '{operation_id:$operation_id,note:$note}')" \
      >/dev/null 2>&1 || true
  fi
  call_tool 99091 "masc_leave" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null 2>&1 || true
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$HARNESS_RESULT_FILE" ] && [ -f "$HARNESS_RESULT_FILE" ]; then
    rm -f "$HARNESS_RESULT_FILE"
  fi
}
trap cleanup EXIT

RUN_SLUG="$(slugify_run_id "$RUN_ID")"
RUN_ARTIFACT_DIR=""
SLOT_SAMPLES_FILE=""
SLOT_TELEMETRY_FILE=""
SWARM_SUMMARY_FILE=""
HARNESS_ARTIFACT_FILE=""

echo "[1/10] build harness binaries"
dune build --root "$REPO_ROOT" bin/main_eio.exe bin/agent_swarm_harness_cli.exe >/dev/null

echo "[2/10] verify local providers"
wait_for_http "${SLOT_URL}/health" 20 1
wait_for_http "${PROVIDER_BASE_URL}/health" 20 1

if [ "$START_SERVER" = "1" ]; then
  echo "[3/10] start isolated masc-mcp on :$PORT"
  rm -rf "$BASE_PATH"
  mkdir -p "$BASE_PATH"
  nohup "$REPO_ROOT/start-masc-mcp.sh" --http --port "$PORT" --base-path "$BASE_PATH" >/tmp/agent-swarm-live-${RUN_ID}.log 2>&1 &
  SERVER_PID="$!"
  wait_for_http "${MASC_URL}/health"
else
  echo "[3/10] reusing existing masc-mcp ${MASC_URL}"
  wait_for_http "${MASC_URL}/health"
fi

RUN_ARTIFACT_DIR="$(resolve_swarm_live_root)/${RUN_SLUG}"
SLOT_SAMPLES_FILE="${RUN_ARTIFACT_DIR}/slot-samples.jsonl"
SLOT_TELEMETRY_FILE="${RUN_ARTIFACT_DIR}/slot-telemetry.json"
SWARM_SUMMARY_FILE="${RUN_ARTIFACT_DIR}/swarm-live-summary.json"
HARNESS_ARTIFACT_FILE="${RUN_ARTIFACT_DIR}/harness-result.json"
rm -rf "$RUN_ARTIFACT_DIR"
mkdir -p "$RUN_ARTIFACT_DIR"

echo "[4/10] describe deterministic swarm manifest"
MANIFEST_JSON="$("$REPO_ROOT/_build/default/bin/agent_swarm_harness_cli.exe" \
  --describe \
  --run-id "$RUN_ID" \
  --masc-url "$MASC_URL" \
  --provider-base-url "$PROVIDER_BASE_URL" \
  --slot-url "$SLOT_URL" \
  --model-id "$MODEL_ID" \
  --worker-count "$WORKER_COUNT" \
  --min-hot-slots "$MIN_HOT_SLOTS" \
  --required-final-markers "$REQUIRED_FINAL_MARKERS" \
  --max-turns "$MAX_TURNS")"
require_json "$MANIFEST_JSON"
EXPECTED_WORKERS="$(printf "%s" "$MANIFEST_JSON" | jq -r '.expected_worker_count')"
SQUAD_ROSTER_JSON="$(printf "%s" "$MANIFEST_JSON" | jq -c '[.workers[].name]')"

echo "[5/10] room/task hygiene"
call_tool_checked 90001 "masc_init" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null
call_tool_checked 90002 "masc_set_room" "$(jq -cn --arg path "$BASE_PATH" '{path:$path}')" >/dev/null
call_tool_checked 90003 "masc_join" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a,capabilities:["agent-swarm","command-plane","benchmark"]}')" >/dev/null
HARNESS_TASK_RAW="$(call_tool_checked 90004 "masc_add_task" "$(jq -cn --arg title "[${RUN_ID}] orchestrate live swarm" --arg desc "Prepare units, tasks, and live harness execution" '{title:$title,description:$desc,priority:1}')")"
HARNESS_TASK_ID="$(extract_added_task_id "$HARNESS_TASK_RAW")"
if [ -z "$HARNESS_TASK_ID" ]; then
  printf "%s\n" "$HARNESS_TASK_RAW" >&2
  echo "failed to extract coordinator task id" >&2
  exit 1
fi
call_tool_checked 90005 "masc_claim" "$(jq -cn --arg a "$HARNESS_AGENT" --arg task_id "$HARNESS_TASK_ID" '{agent_name:$a,task_id:$task_id}')" >/dev/null
call_tool_checked 90006 "masc_plan_set_task" "$(jq -cn --arg task_id "$HARNESS_TASK_ID" '{task_id:$task_id}')" >/dev/null
call_tool_checked 90007 "masc_heartbeat" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null

echo "[6/10] define company/platoon/squad"
call_tool_checked 90010 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" '{unit_id:("company-" + $run_id),kind:"company",label:("Live Swarm Company " + $run_id),leader_id:"swarm-harness"}')" >/dev/null
call_tool_checked 90011 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" '{unit_id:("platoon-" + $run_id),kind:"platoon",label:("Live Swarm Platoon " + $run_id),parent_unit_id:("company-" + $run_id),leader_id:"swarm-harness",policy:{autonomy_level:"L4_Autonomous",escalation_timeout_sec:180}}')" >/dev/null
call_tool_checked 90012 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" --argjson roster "$SQUAD_ROSTER_JSON" '{unit_id:("squad-" + $run_id),kind:"squad",label:("Live Swarm Squad " + $run_id),parent_unit_id:("platoon-" + $run_id),leader_id:"swarm-harness",roster:$roster,policy:{autonomy_level:"L4_Autonomous",escalation_timeout_sec:180},budget:{headcount_cap:16,active_operation_cap:1}}')" >/dev/null

echo "[7/10] start managed operation"
OPERATION_RAW="$(call_tool_checked 90120 "masc_operation_start" "$(jq -cn --arg run_id "$RUN_ID" --arg expected_workers "$EXPECTED_WORKERS" --arg required_final_markers "$REQUIRED_FINAL_MARKERS" --arg min_hot_slots "$MIN_HOT_SLOTS" '{assigned_unit_id:("squad-" + $run_id),objective:("Run deterministic " + $expected_workers + "-worker live harness " + $run_id),autonomy_level:"L4_Autonomous",policy_class:"guarded",budget_class:"standard",note:("run_id=" + $run_id + " worker_count=" + $expected_workers + " required_final_markers=" + $required_final_markers + " min_hot_slots=" + $min_hot_slots)}')")"
OPERATION_ID="$(printf "%s" "$OPERATION_RAW" | extract_result | jq -r '.operation_id // empty')"
if [ -z "$OPERATION_ID" ]; then
  printf "%s\n" "$OPERATION_RAW" >&2
  echo "operation_id missing" >&2
  exit 1
fi
call_tool_checked 90121 "masc_dispatch_tick" "$(jq -cn --arg operation_id "$OPERATION_ID" '{operation_id:$operation_id}')" >/dev/null

echo "[8/10] seed per-worker tasks"
printf "%s" "$MANIFEST_JSON" \
  | jq -c '.workers[]' \
  | while IFS= read -r worker; do
      TITLE="$(printf "%s" "$worker" | jq -r '.task_title')"
      DESC="$(printf "%s" "$worker" | jq -r '.task_description')"
      call_tool_checked 90100 "masc_add_task" "$(jq -cn --arg title "$TITLE" --arg description "$DESC" '{title:$title,description:$description,priority:2}')" >/dev/null
    done
echo "[9/10] run live harness against local qwen"
HARNESS_RESULT_FILE="$(mktemp -t agent-swarm-live-result)"
start_slot_sampler
"$REPO_ROOT/_build/default/bin/agent_swarm_harness_cli.exe" \
  --run-id "$RUN_ID" \
  --masc-url "$MASC_URL" \
  --provider-base-url "$PROVIDER_BASE_URL" \
  --slot-url "$SLOT_URL" \
  --model-id "$MODEL_ID" \
  --worker-count "$WORKER_COUNT" \
  --min-hot-slots "$MIN_HOT_SLOTS" \
  --required-final-markers "$REQUIRED_FINAL_MARKERS" \
  --max-turns "$MAX_TURNS" >"$HARNESS_RESULT_FILE" &
HARNESS_PID="$!"

attempt=0
RUN_ID_QUERY="$(urlencode "$RUN_ID")"
OPERATION_ID_QUERY="$(urlencode "$OPERATION_ID")"
while [ "$attempt" -lt 60 ]; do
  SWARM_LIVE_JSON="$(curl -fsS "${MASC_URL}/api/v1/command-plane/swarm?run_id=${RUN_ID_QUERY}&operation_id=${OPERATION_ID_QUERY}")"
  LIVE_WORKERS="$(printf "%s" "$SWARM_LIVE_JSON" | jq -r '.summary.live_workers // 0')"
  if [ "$LIVE_WORKERS" -ge "$EXPECTED_WORKERS" ]; then
    break
  fi
  if ! kill -0 "$HARNESS_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  attempt=$((attempt + 1))
done

wait "$HARNESS_PID"
HARNESS_PID=""
HARNESS_RESULT="$(cat "$HARNESS_RESULT_FILE")"
require_json "$HARNESS_RESULT"
stop_slot_sampler
cp "$HARNESS_RESULT_FILE" "$HARNESS_ARTIFACT_FILE"
write_slot_telemetry >/dev/null
write_harness_summary >/dev/null

echo "[10/10] checkpoint + finalize"
SUCCESSFUL_WORKERS="$(printf "%s" "$HARNESS_RESULT" | jq -r '.summary.successful_workers')"
call_tool_checked 90130 "masc_operation_checkpoint" "$(jq -cn --arg operation_id "$OPERATION_ID" --arg checkpoint_ref "live-harness-${RUN_ID}" --arg note "successful_workers=${SUCCESSFUL_WORKERS}/${EXPECTED_WORKERS}" '{operation_id:$operation_id,checkpoint_ref:$checkpoint_ref,note:$note}')" >/dev/null

SWARM_JSON="$(curl -fsS "${MASC_URL}/api/v1/command-plane/swarm?run_id=${RUN_ID_QUERY}&operation_id=${OPERATION_ID_QUERY}")"
require_json "$SWARM_JSON"
PASS="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.pass // false')"
JOINED="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.joined_workers // 0')"
TASK_BOUND="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.current_task_bound // 0')"
FRESH="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.fresh_heartbeats // 0')"
LIVE="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.live_workers // 0')"
PEAK_HOT_SLOTS="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.peak_hot_slots // 0')"
COMPLETED_WORKERS="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.completed_workers // 0')"
FINAL_MARKERS_SEEN="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.final_markers_seen // 0')"
PASS_HOT="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.pass_hot_concurrency // false')"
PASS_E2E="$(printf "%s" "$SWARM_JSON" | jq -r '.summary.pass_end_to_end // false')"
if [ "$PASS" = "true" ]; then
  call_tool_checked 90131 "masc_operation_finalize" "$(jq -cn --arg operation_id "$OPERATION_ID" --arg note "${EXPECTED_WORKERS}-worker live harness passed" '{operation_id:$operation_id,note:$note}')" >/dev/null
  OPERATION_ID=""
fi

echo "[11/11] summary"
printf "%s\n" "$SWARM_JSON" | jq \
  --arg expected "$EXPECTED_WORKERS" \
  --arg joined "$JOINED" \
  --arg task_bound "$TASK_BOUND" \
  --arg fresh "$FRESH" \
  --arg live "$LIVE" \
  '{run_id,room_id,operation_id,recommended_next_tool,summary,blockers,truth_notes}'

if [ "$PASS" != "true" ]; then
  echo "FAIL: swarm harness did not pass (${JOINED}/${EXPECTED_WORKERS} joined, ${TASK_BOUND}/${EXPECTED_WORKERS} task-bound, ${FRESH}/${EXPECTED_WORKERS} fresh, completed=${COMPLETED_WORKERS}/${EXPECTED_WORKERS}, final=${FINAL_MARKERS_SEEN}/${REQUIRED_FINAL_MARKERS}, peak_hot=${PEAK_HOT_SLOTS}, pass_hot=${PASS_HOT}, pass_e2e=${PASS_E2E}, live=${LIVE})" >&2
  exit 1
fi
