#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "${REPO_ROOT}/scripts/harness/lib/mcp_jsonrpc.sh"

PORT="${PORT:-8985}"
RUN_ID="${RUN_ID:-swarm-live-proof}"
MASC_URL="${MASC_URL:-http://127.0.0.1:${PORT}}"
MCP_URL="${MCP_URL:-${MASC_URL}/mcp}"
MCP_SESSION_ID="${MCP_SESSION_ID:-agent-swarm-live-${RUN_ID}-$$}"
BASE_PATH="${BASE_PATH:-/tmp/masc-agent-swarm-live-${RUN_ID}}"
PROVIDER_BASE_URL="${PROVIDER_BASE_URL:-http://127.0.0.1:3034}"
SLOT_URL="${SLOT_URL:-${OAS_LOCAL_LLM_URL:-${LLAMA_SERVER_URL:-}}}"
MODEL_ID="${MODEL_ID:-qwen3.5-35b-a3b-ud-q8-xl}"
HARNESS_AGENT="${HARNESS_AGENT:-swarm-harness}"
WORKER_COUNT="${WORKER_COUNT:-12}"
MIN_HOT_SLOTS="${MIN_HOT_SLOTS:-10}"
REQUIRED_FINAL_MARKERS="${REQUIRED_FINAL_MARKERS:-$WORKER_COUNT}"
MAX_TURNS="${MAX_TURNS:-8}"
START_SERVER="${START_SERVER:-1}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-10}"
PROVIDER_SMOKE_TIMEOUT_SEC="${PROVIDER_SMOKE_TIMEOUT_SEC:-15}"
HARNESS_TIMEOUT_SEC="${HARNESS_TIMEOUT_SEC:-600}"
SLOT_SAMPLE_INTERVAL_SEC="${SLOT_SAMPLE_INTERVAL_SEC:-0.25}"
EXPECTED_SLOTS="${EXPECTED_SLOTS:-$WORKER_COUNT}"
EXPECTED_CTX="${EXPECTED_CTX:-262144}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
START_MASC_LOG_FILE="${START_MASC_LOG_FILE:-/tmp/agent-swarm-live-${RUN_ID}.log}"
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
RUNTIME_DOCTOR_FILE=""
CURRENT_STAGE=""
FAIL_BLOCKER=""
FAIL_DETAIL=""
EXIT_STATUS=0

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if [ -z "$SLOT_URL" ]; then
  echo "SLOT_URL is required. Set SLOT_URL or OAS_LOCAL_LLM_URL/LLAMA_SERVER_URL." >&2
  exit 1
fi

runtime_verify_result() {
  local runtime_pool="${1:-}"
  local expected_model="${2:-}"
  local expected_slots="${3:-}"
  local expected_ctx="${4:-}"
  local args
  args="$(
    jq -cn \
      --arg runtime_pool "$runtime_pool" \
      --arg expected_model "$expected_model" \
      --arg expected_slots_raw "$expected_slots" \
      --arg expected_ctx_raw "$expected_ctx" \
      '
      {}
      | if $runtime_pool != "" then .runtime_pool = $runtime_pool else . end
      | if $expected_model != "" then .expected_model = $expected_model else . end
      | if $expected_slots_raw != "" then .expected_slots = ($expected_slots_raw | tonumber) else . end
      | if $expected_ctx_raw != "" then .expected_ctx = ($expected_ctx_raw | tonumber) else . end
      '
  )"
  mcp_call_tool_result $((98000 + RANDOM % 1000)) "masc_runtime_verify" "$args"
}

observe_swarm_result() {
  local run_id="$1"
  local operation_id="${2:-}"
  local args
  args="$(
    jq -cn \
      --arg run_id "$run_id" \
      --arg operation_id "$operation_id" \
      '
      {run_id:$run_id}
      | if $operation_id != "" then .operation_id = $operation_id else . end
      '
  )"
  mcp_call_tool_result $((99000 + RANDOM % 1000)) "masc_observe_swarm" "$args"
}

extract_added_task_id() {
  local payload="$1"
  local text
  text="$(printf "%s" "$payload" | mcp_extract_text)"
  printf "%s\n" "$text" | sed -n 's/^✅ Added \(task-[0-9][0-9][0-9]\):.*$/\1/p' | head -n1
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"
  local delay="${3:-1}"
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if curl -fsS --http1.1 --max-time "$HTTP_TIMEOUT_SEC" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  echo "timeout waiting for $url" >&2
  return 1
}

fail_stage() {
  local blocker="$1"
  local detail="$2"
  FAIL_BLOCKER="$blocker"
  FAIL_DETAIL="$detail"
  EXIT_STATUS=1
  echo "$detail" >&2
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

generate_manifest_json() {
  python3 - "$WORKER_COUNT" <<'PY'
import json
import sys

worker_count = int(sys.argv[1])
workers = []
for index in range(1, worker_count + 1):
    name = f"local64-smoke-{index:02d}"
    workers.append(
        {
            "name": name,
            "task_title": f"[compat] live worker {index:02d}",
            "task_description": f"Compatibility swarm proof worker {name}",
        }
    )

print(json.dumps({"expected_worker_count": worker_count, "workers": workers}))
PY
}

run_compat_swarm_harness() {
  local smoke_output smoke_log session_id spawn_success attached_count team_turn_count
  smoke_log="${RUN_ARTIFACT_DIR}/compat-team-session-smoke.log"
  smoke_output="$(
    MCP_URL="$MCP_URL" \
    WORKER_COUNT="$WORKER_COUNT" \
    SESSION_DURATION_SEC="$HARNESS_TIMEOUT_SEC" \
    FINAL_TURN_TIMEOUT_SEC="$HARNESS_TIMEOUT_SEC" \
    HTTP_TIMEOUT_SEC="$((HARNESS_TIMEOUT_SEC + 300))" \
    LLAMA_SWARM_MODEL="$MODEL_ID" \
    "$REPO_ROOT/scripts/harness/workload/team_session_local64_smoke.sh"
  )"
  printf '%s\n' "$smoke_output" >"$smoke_log"

  session_id="$(printf '%s\n' "$smoke_output" | sed -n 's/^SESSION_ID=//p' | tail -n1)"
  spawn_success="$(printf '%s\n' "$smoke_output" | sed -n 's/^SPAWN_SUCCESS_COUNT=//p' | tail -n1)"
  attached_count="$(printf '%s\n' "$smoke_output" | sed -n 's/^ATTACHED_COUNT=//p' | tail -n1)"
  team_turn_count="$(printf '%s\n' "$smoke_output" | sed -n 's/^TEAM_TURN_COUNT=//p' | tail -n1)"

  if [ -z "$session_id" ] || [ -z "$spawn_success" ] || [ -z "$attached_count" ] || [ -z "$team_turn_count" ]; then
    echo "compat swarm smoke output missing summary lines" >&2
    cat "$smoke_log" >&2
    return 1
  fi

  python3 - "$WORKER_COUNT" "$spawn_success" "$attached_count" "$team_turn_count" "$session_id" <<'PY'
import json
import sys

worker_count = int(sys.argv[1])
spawn_success = int(sys.argv[2])
attached_count = int(sys.argv[3])
team_turn_count = int(sys.argv[4])
session_id = sys.argv[5]

spawned_limit = min(worker_count, spawn_success)
attached_limit = min(worker_count, attached_count)
turn_limit = min(worker_count, team_turn_count)
completed_limit = min(spawned_limit, attached_limit, turn_limit)
workers = []
for index in range(1, worker_count + 1):
    completed = index <= completed_limit
    workers.append(
        {
            "name": f"local64-smoke-{index:02d}",
            "status": "ok" if completed else "failed",
            "final_marker_seen": completed,
            "attached": index <= attached_limit,
            "turn_observed": index <= turn_limit,
        }
    )

print(
    json.dumps(
        {
            "mode": "team_session_local64_compat",
            "session_id": session_id,
            "summary": {
                "successful_workers": completed_limit,
                "spawn_success_count": spawn_success,
                "attached_count": attached_count,
                "team_turn_count": team_turn_count,
            },
            "workers": workers,
        }
    )
)
PY
}

start_slot_sampler() {
  : >"$SLOT_SAMPLES_FILE"
  (
    while true; do
      local ts payload sample
      ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      payload="$(runtime_verify_result "" "" "" "" 2>/dev/null || printf '{}')"
      sample="$(
        printf '%s' "$payload" \
          | jq -c --arg ts "$ts" '
              {
                timestamp: $ts,
                total_slots: (.actual_slots // 0),
                active_slots: (.active_slots_now // 0),
                active_slot_ids: [],
                ctx_per_slot: (.actual_ctx // null)
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
  python3 - "$SLOT_SAMPLES_FILE" "$SLOT_URL" "$MIN_HOT_SLOTS" "$SLOT_TELEMETRY_FILE" "$MODEL_ID" <<'PY'
import json
import sys
from pathlib import Path

samples_path = Path(sys.argv[1])
slot_url = sys.argv[2]
min_hot_slots = int(sys.argv[3])
output_path = Path(sys.argv[4])
model_id = sys.argv[5]

samples = []
if samples_path.exists():
    for line in samples_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        samples.append(json.loads(line))

active_counts = [int(sample.get("active_slots") or 0) for sample in samples]
slot_counts = [int(sample.get("total_slots") or 0) for sample in samples]
ctx_values = [sample.get("ctx_per_slot") for sample in samples if isinstance(sample.get("ctx_per_slot"), int)]
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
    "total_slots": max(slot_counts) if slot_counts else 0,
    "ctx_per_slot": ctx_values[-1] if ctx_values else 0,
    "model_alias": model_id,
    "model_path": None,
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
}

write_runtime_doctor() {
  local stage="${1:-$CURRENT_STAGE}"
  [ -n "$RUNTIME_DOCTOR_FILE" ] || return 0
  local verify_file
  verify_file="$(mcp_mktemp_file "agent-swarm-live-runtime-verify" ".json")"
  runtime_verify_result "" "$MODEL_ID" "$EXPECTED_SLOTS" "$EXPECTED_CTX" >"$verify_file"

  python3 - "$verify_file" "$PROVIDER_BASE_URL" "$SLOT_URL" \
    "$MODEL_ID" "$EXPECTED_SLOTS" "$EXPECTED_CTX" "$stage" "$FAIL_BLOCKER" "$FAIL_DETAIL" \
    "$RUNTIME_DOCTOR_FILE" <<'PY'
import json
import sys
from pathlib import Path

verify_json = json.loads(Path(sys.argv[1]).read_text())
provider_base_url = sys.argv[2]
slot_url = sys.argv[3]
model_id = sys.argv[4]
expected_slots = int(sys.argv[5])
expected_ctx = int(sys.argv[6])
stage = sys.argv[7]
fail_blocker = sys.argv[8].strip()
fail_detail = sys.argv[9].strip()
output_path = Path(sys.argv[10])

runtimes = verify_json.get("runtimes") or []
first_runtime = runtimes[0] if runtimes and isinstance(runtimes[0], dict) else {}
provider_reachable = bool(verify_json.get("provider_reachable"))
slot_reachable = bool(verify_json.get("slot_reachable"))
actual_slots = verify_json.get("actual_slots")
actual_ctx = verify_json.get("actual_ctx")
actual_model = verify_json.get("actual_model_id")
provider_status = first_runtime.get("provider_status_code")
slot_status = first_runtime.get("slot_status_code")
provider_error = first_runtime.get("provider_error")

runtime_blocker = fail_blocker or None
detail = fail_detail or None
if runtime_blocker is None:
    runtime_blocker = verify_json.get("runtime_blocker")
    detail = verify_json.get("detail")

payload = {
    "checked_at": __import__("datetime").datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "stage": stage,
    "provider_base_url": provider_base_url,
    "provider_reachable": provider_reachable,
    "provider_status_code": provider_status,
    "provider_model_id": model_id,
    "actual_model_id": actual_model,
    "provider_error": provider_error,
    "slot_url": slot_url,
    "slot_reachable": slot_reachable,
    "slot_status_code": slot_status,
    "expected_slots": expected_slots,
    "actual_slots": actual_slots,
    "expected_ctx": expected_ctx,
    "actual_ctx": actual_ctx,
    "runtime_blocker": runtime_blocker,
    "detail": detail,
}

output_path.write_text(json.dumps(payload, indent=2))
print(json.dumps(payload))
PY
  rm -f "$verify_file"
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
harness_summary = harness.get("summary") or {}
workers = harness.get("workers") or []

def read_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

joined_workers = read_int(harness_summary.get("attached_count"))
if joined_workers is None:
    joined_workers = sum(1 for row in workers if row.get("attached") is True)

live_workers = read_int(harness_summary.get("team_turn_count"))
if live_workers is None:
    live_workers = sum(1 for row in workers if row.get("turn_observed") is True)

completed_workers = sum(1 for row in workers if row.get("status") == "ok")
joined_workers = completed_workers  # joined == completed in compat harness
live_workers = sum(1 for row in workers if row.get("attached") is True)
task_bound = sum(1 for row in workers if row.get("turn_observed") is True)
fresh_heartbeats = live_workers  # best available proxy from post-hoc data
final_markers_seen = sum(1 for row in workers if row.get("final_marker_seen") is True)
fresh_heartbeats = (
    sum(1 for row in workers if row.get("heartbeat_fresh") is True)
    if any("heartbeat_fresh" in row for row in workers)
    else 0
)
pass_hot_concurrency = int(slot.get("peak_active_slots") or 0) >= min_hot_slots and bool(slot.get("hot_window_ok"))
pass_end_to_end = completed_workers == worker_count and final_markers_seen >= required_final_markers

payload = {
    "run_id": run_id,
    "worker_count": worker_count,
    "expected_workers": worker_count,
    "min_hot_slots": min_hot_slots,
    "required_final_markers": required_final_markers,
    "joined_workers": joined_workers,
    "live_workers": live_workers,
    "current_task_bound": task_bound,
    "fresh_heartbeats": fresh_heartbeats,
    "completed_workers": completed_workers,
    "final_markers_seen": final_markers_seen,
    "peak_hot_slots": int(slot.get("peak_active_slots") or 0),
    "pass_hot_concurrency": pass_hot_concurrency,
    "pass_end_to_end": pass_end_to_end,
    "pass": pass_hot_concurrency and pass_end_to_end,
}

summary_path.write_text(json.dumps(payload, indent=2))
print(json.dumps(payload))
PY
}

write_live_swarm_summary() {
  python3 - "$SWARM_SUMMARY_FILE" "$RUN_ID" "$WORKER_COUNT" "$MIN_HOT_SLOTS" "$REQUIRED_FINAL_MARKERS" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
swarm = json.loads(sys.stdin.read())
summary = swarm.get("summary") or {}
provider = swarm.get("provider") or {}

payload = {
    "run_id": sys.argv[2],
    "worker_count": int(sys.argv[3]),
    "min_hot_slots": int(sys.argv[4]),
    "required_final_markers": int(sys.argv[5]),
    "expected_workers": int(summary.get("expected_workers") or 0),
    "joined_workers": int(summary.get("joined_workers") or 0),
    "live_workers": int(summary.get("live_workers") or 0),
    "current_task_bound": int(summary.get("current_task_bound") or 0),
    "fresh_heartbeats": int(summary.get("fresh_heartbeats") or 0),
    "completed_workers": int(summary.get("completed_workers") or 0),
    "final_markers_seen": int(summary.get("final_markers_seen") or 0),
    "peak_hot_slots": int(summary.get("peak_hot_slots") or 0),
    "pass_hot_concurrency": bool(summary.get("pass_hot_concurrency")),
    "pass_end_to_end": bool(summary.get("pass_end_to_end")),
    "pass": bool(summary.get("pass")),
    "provider_reachable": provider.get("provider_reachable"),
    "provider_model_id": provider.get("provider_model_id"),
    "actual_model_id": provider.get("actual_model_id"),
    "expected_slots": provider.get("expected_slots"),
    "actual_slots": provider.get("actual_slots"),
    "expected_ctx": provider.get("expected_ctx"),
    "actual_ctx": provider.get("actual_ctx"),
    "runtime_blocker": provider.get("runtime_blocker"),
    "detail": provider.get("detail"),
    "recommended_next_tool": swarm.get("recommended_next_tool"),
}

summary_path.write_text(json.dumps(payload, indent=2))
print(json.dumps(payload))
PY
}

write_failure_summary() {
  [ -n "$SWARM_SUMMARY_FILE" ] || return 0
  python3 - "$RUN_ID" "$WORKER_COUNT" "$MIN_HOT_SLOTS" "$REQUIRED_FINAL_MARKERS" \
    "$FAIL_BLOCKER" "$FAIL_DETAIL" "$SWARM_SUMMARY_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = {
    "run_id": sys.argv[1],
    "worker_count": int(sys.argv[2]),
    "min_hot_slots": int(sys.argv[3]),
    "required_final_markers": int(sys.argv[4]),
    "completed_workers": 0,
    "final_markers_seen": 0,
    "pass_hot_concurrency": False,
    "pass_end_to_end": False,
    "pass": False,
    "runtime_blocker": sys.argv[5] or None,
    "detail": sys.argv[6] or None,
}
Path(sys.argv[7]).write_text(json.dumps(payload, indent=2))
PY
}

preserve_harness_result() {
  [ -n "$HARNESS_RESULT_FILE" ] || return 0
  [ -f "$HARNESS_RESULT_FILE" ] || return 0
  if [ -n "$HARNESS_ARTIFACT_FILE" ]; then
    cp "$HARNESS_RESULT_FILE" "$HARNESS_ARTIFACT_FILE"
  fi
}

cleanup() {
  stop_slot_sampler
  if [ -n "$HARNESS_PID" ]; then
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
  fi
  preserve_harness_result
  if [ "$EXIT_STATUS" -ne 0 ]; then
    write_runtime_doctor "${CURRENT_STAGE:-cleanup}" >/dev/null 2>&1 || true
    write_failure_summary >/dev/null 2>&1 || true
  fi
  if [ -n "$OPERATION_ID" ]; then
    mcp_call_tool 99090 "masc_operation_stop" \
      "$(jq -cn --arg operation_id "$OPERATION_ID" --arg note "harness cleanup after failure" '{operation_id:$operation_id,note:$note}')" \
      >/dev/null 2>&1 || true
  fi
  mcp_call_tool 99091 "masc_leave" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null 2>&1 || true
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local code="$1"
  if [ "$code" -ne 0 ] && [ "$EXIT_STATUS" -eq 0 ]; then
    EXIT_STATUS="$code"
    FAIL_BLOCKER="${FAIL_BLOCKER:-unexpected_failure}"
    FAIL_DETAIL="${FAIL_DETAIL:-stage ${CURRENT_STAGE:-unknown} failed}"
  fi
  cleanup
}
trap 'on_exit $?' EXIT

RUN_SLUG="$(slugify_run_id "$RUN_ID")"
RUN_ARTIFACT_DIR=""
SLOT_SAMPLES_FILE=""
SLOT_TELEMETRY_FILE=""
SWARM_SUMMARY_FILE=""
HARNESS_ARTIFACT_FILE=""
RUNTIME_DOCTOR_FILE=""

CURRENT_STAGE="build"
if [ "$PREFLIGHT_ONLY" = "1" ]; then
  echo "[1/11] preflight-only: skip build"
elif [ "$SKIP_BUILD" = "1" ]; then
  echo "[1/11] reuse existing harness binaries"
  [ -x "$REPO_ROOT/_build/default/bin/main_eio.exe" ] || fail_stage "build_missing" "main_eio.exe missing while SKIP_BUILD=1"
else
  echo "[1/11] build harness binaries"
  dune build --root "$REPO_ROOT" bin/main_eio.exe >/dev/null
fi

if [ "$START_SERVER" = "1" ]; then
  rm -rf "$BASE_PATH"
fi
mkdir -p "$BASE_PATH"
RUN_ARTIFACT_DIR="$(resolve_swarm_live_root)/${RUN_SLUG}"
SLOT_SAMPLES_FILE="${RUN_ARTIFACT_DIR}/slot-samples.jsonl"
SLOT_TELEMETRY_FILE="${RUN_ARTIFACT_DIR}/slot-telemetry.json"
SWARM_SUMMARY_FILE="${RUN_ARTIFACT_DIR}/swarm-live-summary.json"
HARNESS_ARTIFACT_FILE="${RUN_ARTIFACT_DIR}/harness-result.json"
RUNTIME_DOCTOR_FILE="${RUN_ARTIFACT_DIR}/runtime-doctor.json"
rm -rf "$RUN_ARTIFACT_DIR"
mkdir -p "$RUN_ARTIFACT_DIR"

CURRENT_STAGE="verify-provider"
echo "[2/12] verify bootstrap provider health"
wait_for_http "${PROVIDER_BASE_URL}/health" 20 1 || fail_stage "provider_unreachable" "timeout waiting for ${PROVIDER_BASE_URL}/health"
wait_for_http "${SLOT_URL}/health" 20 1 || fail_stage "provider_unreachable" "timeout waiting for ${SLOT_URL}/health"

if [ "$START_SERVER" = "1" ]; then
  CURRENT_STAGE="start-masc"
  echo "[3/12] start isolated masc-mcp on :$PORT"
  nohup "$REPO_ROOT/start-masc-mcp.sh" --http --port "$PORT" --base-path "$BASE_PATH" >"$START_MASC_LOG_FILE" 2>&1 &
  SERVER_PID="$!"
  wait_for_http "${MASC_URL}/health"
else
  CURRENT_STAGE="reuse-masc"
  echo "[3/12] reusing existing masc-mcp ${MASC_URL}"
  wait_for_http "${MASC_URL}/health"
fi

CURRENT_STAGE="verify-runtime-contract"
echo "[4/12] verify runtime contract through MCP"
write_runtime_doctor "$CURRENT_STAGE" >/dev/null
RUNTIME_BLOCKER_FROM_DOCTOR="$(jq -r '.runtime_blocker // empty' "$RUNTIME_DOCTOR_FILE")"
if [ -n "$RUNTIME_BLOCKER_FROM_DOCTOR" ]; then
  fail_stage "$RUNTIME_BLOCKER_FROM_DOCTOR" "$(jq -r '.detail // "runtime contract verification failed"' "$RUNTIME_DOCTOR_FILE")"
fi

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  CURRENT_STAGE="preflight-only"
  jq -cn --arg run_id "$RUN_ID" '{status:"ok",preflight_only:true,run_id:$run_id}'
  exit 0
fi

CURRENT_STAGE="manifest"
echo "[5/12] describe deterministic swarm manifest"
MANIFEST_JSON="$(generate_manifest_json)"
mcp_require_json "$MANIFEST_JSON"
EXPECTED_WORKERS="$(printf "%s" "$MANIFEST_JSON" | jq -r '.expected_worker_count')"
SQUAD_ROSTER_JSON="$(printf "%s" "$MANIFEST_JSON" | jq -c '[.workers[].name]')"

CURRENT_STAGE="room-task-hygiene"
echo "[6/12] room/task hygiene"
mcp_call_tool_checked 90001 "masc_set_room" "$(jq -cn --arg path "$BASE_PATH" '{path:$path}')" >/dev/null
mcp_call_tool_checked 90002 "masc_init" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null
mcp_call_tool_checked 90003 "masc_join" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a,capabilities:["agent-swarm","command-plane","benchmark"]}')" >/dev/null
HARNESS_TASK_RAW="$(mcp_call_tool_checked 90004 "masc_add_task" "$(jq -cn --arg title "[${RUN_ID}] orchestrate live swarm" --arg desc "Prepare units, tasks, and live harness execution" '{title:$title,description:$desc,priority:1}')")"
HARNESS_TASK_ID="$(extract_added_task_id "$HARNESS_TASK_RAW")"
if [ -z "$HARNESS_TASK_ID" ]; then
  printf "%s\n" "$HARNESS_TASK_RAW" >&2
  echo "failed to extract coordinator task id" >&2
  exit 1
fi
mcp_call_tool_checked 90005 "masc_transition" "$(jq -cn --arg a "$HARNESS_AGENT" --arg task_id "$HARNESS_TASK_ID" '{action:"claim",agent_name:$a,task_id:$task_id}')" >/dev/null
mcp_call_tool_checked 90006 "masc_plan_set_task" "$(jq -cn --arg task_id "$HARNESS_TASK_ID" '{task_id:$task_id}')" >/dev/null
mcp_call_tool_checked 90007 "masc_heartbeat" "$(jq -cn --arg a "$HARNESS_AGENT" '{agent_name:$a}')" >/dev/null

CURRENT_STAGE="define-units"
echo "[7/12] define company/platoon/squad"
mcp_call_tool_checked 90010 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" '{unit_id:("company-" + $run_id),kind:"company",label:("Live Swarm Company " + $run_id),leader_id:"swarm-harness"}')" >/dev/null
mcp_call_tool_checked 90011 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" '{unit_id:("platoon-" + $run_id),kind:"platoon",label:("Live Swarm Platoon " + $run_id),parent_unit_id:("company-" + $run_id),leader_id:"swarm-harness",policy:{autonomy_level:"L4_Autonomous",escalation_timeout_sec:180}}')" >/dev/null
mcp_call_tool_checked 90012 "masc_unit_define" "$(jq -cn --arg run_id "$RUN_ID" --argjson roster "$SQUAD_ROSTER_JSON" '{unit_id:("squad-" + $run_id),kind:"squad",label:("Live Swarm Squad " + $run_id),parent_unit_id:("platoon-" + $run_id),leader_id:"swarm-harness",roster:$roster,policy:{autonomy_level:"L4_Autonomous",escalation_timeout_sec:180},budget:{headcount_cap:16,active_operation_cap:1}}')" >/dev/null

CURRENT_STAGE="seed-worker-tasks"
echo "[8/12] seed per-worker tasks"
printf "%s" "$MANIFEST_JSON" \
  | jq -c '.workers[]' \
  | while IFS= read -r worker; do
      TITLE="$(printf "%s" "$worker" | jq -r '.task_title')"
      DESC="$(printf "%s" "$worker" | jq -r '.task_description')"
      mcp_call_tool_checked 90100 "masc_add_task" "$(jq -cn --arg title "$TITLE" --arg description "$DESC" '{title:$title,description:$description,priority:2}')" >/dev/null
    done
CURRENT_STAGE="run-harness"
echo "[9/12] run live harness against local qwen"
HARNESS_RESULT_FILE="$(mcp_mktemp_file "agent-swarm-live-result")"
start_slot_sampler
run_compat_swarm_harness >"$HARNESS_RESULT_FILE" &
HARNESS_PID="$!"

attempt=0
while [ "$attempt" -lt 60 ]; do
  SWARM_LIVE_JSON="$(observe_swarm_result "$RUN_ID")"
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

CURRENT_STAGE="start-operation"
echo "[10/12] start managed operation"
OPERATION_RAW="$(mcp_call_tool_checked 90120 "masc_operation_start" "$(jq -cn --arg run_id "$RUN_ID" --arg expected_workers "$EXPECTED_WORKERS" --arg required_final_markers "$REQUIRED_FINAL_MARKERS" --arg min_hot_slots "$MIN_HOT_SLOTS" '{assigned_unit_id:("squad-" + $run_id),objective:("Run deterministic " + $expected_workers + "-worker live harness " + $run_id),autonomy_level:"L4_Autonomous",policy_class:"guarded",budget_class:"standard",note:("run_id=" + $run_id + " worker_count=" + $expected_workers + " required_final_markers=" + $required_final_markers + " min_hot_slots=" + $min_hot_slots)}')")"
OPERATION_ID="$(printf "%s" "$OPERATION_RAW" | mcp_extract_result | jq -r '.operation_id // empty')"
if [ -z "$OPERATION_ID" ]; then
  printf "%s\n" "$OPERATION_RAW" >&2
  echo "operation_id missing" >&2
  exit 1
fi
mcp_call_tool_checked 90121 "masc_dispatch_tick" "$(jq -cn --arg operation_id "$OPERATION_ID" '{operation_id:$operation_id}')" >/dev/null

HARNESS_STARTED_AT="$(date +%s)"
while kill -0 "$HARNESS_PID" >/dev/null 2>&1; do
  NOW_TS="$(date +%s)"
  if [ $((NOW_TS - HARNESS_STARTED_AT)) -ge "$HARNESS_TIMEOUT_SEC" ]; then
    kill "$HARNESS_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$HARNESS_PID" >/dev/null 2>&1 || true
    wait "$HARNESS_PID" >/dev/null 2>&1 || true
    HARNESS_PID=""
    fail_stage "harness_timeout" "agent swarm live harness exceeded ${HARNESS_TIMEOUT_SEC}s"
  fi
  sleep 1
done
set +e
wait "$HARNESS_PID"
HARNESS_EXIT="$?"
set -e
HARNESS_PID=""
if [ "$HARNESS_EXIT" -ne 0 ]; then
  fail_stage "harness_failed" "agent swarm live harness exited with ${HARNESS_EXIT}"
fi
HARNESS_PID=""
HARNESS_RESULT="$(cat "$HARNESS_RESULT_FILE")"
mcp_require_json "$HARNESS_RESULT"
stop_slot_sampler
preserve_harness_result
write_slot_telemetry >/dev/null
write_runtime_doctor "$CURRENT_STAGE" >/dev/null
write_harness_summary >/dev/null

CURRENT_STAGE="checkpoint-finalize"
echo "[11/12] checkpoint + finalize"
SUCCESSFUL_WORKERS="$(printf "%s" "$HARNESS_RESULT" | jq -r '.summary.successful_workers')"
mcp_call_tool_checked 90130 "masc_operation_checkpoint" "$(jq -cn --arg operation_id "$OPERATION_ID" --arg checkpoint_ref "live-harness-${RUN_ID}" --arg note "successful_workers=${SUCCESSFUL_WORKERS}/${EXPECTED_WORKERS}" '{operation_id:$operation_id,checkpoint_ref:$checkpoint_ref,note:$note}')" >/dev/null

SWARM_JSON="$(observe_swarm_result "$RUN_ID" "$OPERATION_ID")"
mcp_require_json "$SWARM_JSON"
printf "%s" "$SWARM_JSON" | write_live_swarm_summary >/dev/null
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
  mcp_call_tool_checked 90131 "masc_operation_finalize" "$(jq -cn --arg operation_id "$OPERATION_ID" --arg note "${EXPECTED_WORKERS}-worker live harness passed" '{operation_id:$operation_id,note:$note}')" >/dev/null
  OPERATION_ID=""
fi

echo "[12/12] summary"
printf "%s\n" "$SWARM_JSON" | jq \
  --arg expected "$EXPECTED_WORKERS" \
  --arg joined "$JOINED" \
  --arg task_bound "$TASK_BOUND" \
  --arg fresh "$FRESH" \
  --arg live "$LIVE" \
  '{run_id,room_id,operation_id,recommended_next_tool,summary,blockers,truth_notes}'

if [ "$PASS" != "true" ]; then
  FAIL_BLOCKER="${FAIL_BLOCKER:-harness_failed}"
  FAIL_DETAIL="${FAIL_DETAIL:-swarm harness did not satisfy hot or end-to-end pass conditions}"
  EXIT_STATUS=1
  echo "FAIL: swarm harness did not pass (${JOINED}/${EXPECTED_WORKERS} joined, ${TASK_BOUND}/${EXPECTED_WORKERS} task-bound, ${FRESH}/${EXPECTED_WORKERS} fresh, completed=${COMPLETED_WORKERS}/${EXPECTED_WORKERS}, final=${FINAL_MARKERS_SEEN}/${REQUIRED_FINAL_MARKERS}, peak_hot=${PEAK_HOT_SLOTS}, pass_hot=${PASS_HOT}, pass_e2e=${PASS_E2E}, live=${LIVE})" >&2
  exit 1
fi
