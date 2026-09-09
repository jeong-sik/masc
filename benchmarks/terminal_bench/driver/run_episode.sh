#!/usr/bin/env bash
# usage: run_episode.sh <instruction-file> <result-json-path>
set -euo pipefail

BENCH=/opt/masc-bench
export MASC_BASE_PATH=$BENCH/base
if [[ -z "${MASC_CONFIG_DIR:-}" && -d "$BENCH/config-rw" ]]; then
  export MASC_CONFIG_DIR="$BENCH/config-rw"
else
  export MASC_CONFIG_DIR="${MASC_CONFIG_DIR:-$BENCH/config}"
fi
MCP_TOKEN="$(cat "$BENCH/token")"
export MCP_TOKEN
source "$BENCH/driver/mcp.sh"

INSTRUCTION_FILE="$1"
RESULT_JSON="$2"
KEEPER_COUNT="${KEEPER_COUNT:-1}"
RUNTIME_ID="${BENCH_RUNTIME_ID:?BENCH_RUNTIME_ID required (e.g. anthropic.claude-fable-5)}"
EPISODE_TIMEOUT_SEC="${EPISODE_TIMEOUT_SEC:-3600}"
POLL_INTERVAL_SEC=10

KEEPER_INSTRUCTIONS="You are an autonomous engineering agent inside a Linux container. \
Complete the task by running shell commands (your tool calls execute in this container as root). \
Work directly; do not ask questions. When the task is verifiably done, finish."

server_ready=0
for _ in $(seq 1 30); do
  if mcp_init 2>/dev/null; then server_ready=1; break; fi
  sleep 2
done
[[ "$server_ready" -eq 1 ]] || { echo "MASC server unreachable" >&2; exit 1; }

lead_msg="$(cat "$INSTRUCTION_FILE")"
if [[ "${KEEPER_COUNT}" -gt 1 ]]; then
  names=""
  for i in $(seq 1 "${KEEPER_COUNT}"); do names="${names} bench-${i}"; done
  lead_msg="You are the lead of a keeper team:${names}. Decompose the task, delegate to the team with your keeper tools, integrate their results, and verify completion yourself.

${lead_msg}"
fi

for i in $(seq 1 "${KEEPER_COUNT}"); do
  k="bench-${i}"
  mcp_call $((100+i)) masc_keeper_up "$(jq -cn \
    --arg name "$k" --arg ins "$KEEPER_INSTRUCTIONS" --arg rid "$RUNTIME_ID" \
    '{name:$name, instructions:$ins, runtime_id:$rid, activation_mode:"manual"}')" 90 >/dev/null
  curl -fsS -m 20 -X POST "http://127.0.0.1:8935/api/v1/keepers/tool-approval-mode" \
    -H "Authorization: Bearer ${MCP_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${k}\",\"mode\":\"yolo\"}" >/dev/null
done

start_epoch="$(date +%s)"
printf '%s' "$lead_msg" > "$BENCH/episode-message.txt"
submit="$(mcp_call 200 masc_keeper_msg \
  "$(jq -cn --arg name bench-1 --rawfile m "$BENCH/episode-message.txt" \
    '{name:$name, message:$m}')" 60)" || {
  sleep 5
  submit="$(mcp_call 200 masc_keeper_msg \
    "$(jq -cn --arg name bench-1 --rawfile m "$BENCH/episode-message.txt" \
      '{name:$name, message:$m}')" 60)" || {
    jq -n \
      --argjson duration_ms $(( ($(date +%s) - start_epoch) * 1000 )) \
      '{state:"Error", duration_ms:$duration_ms, tool_calls:0,
        duplicate_tool_calls:0, final:{}}' \
      > "$RESULT_JSON"
    cat "$RESULT_JSON"
    exit 1
  }
}
op_id="$(printf '%s' "$submit" | jq -r '.operation_id // empty')"
[[ -n "$op_id" ]] || { echo "keeper_msg returned no operation_id: $submit" >&2; exit 1; }

state="Timeout"; final='{}'
deadline=$(( start_epoch + EPISODE_TIMEOUT_SEC ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  st="$(mcp_call 300 masc_keeper_delegate_status "$(jq -cn \
    --arg op "$op_id" \
    '{target:{kind:"keeper",name:"bench-1"}, operation_id:$op}')" 30)" || true
  s="$(printf '%s' "$st" | jq -r '.state // empty' 2>/dev/null || true)"
  case "$s" in
    Succeeded|Failed|Cancelled) state="$s"; final="$st"; break ;;
  esac
  sleep "$POLL_INTERVAL_SEC"
done
end_epoch="$(date +%s)"

for i in $(seq 1 "${KEEPER_COUNT}"); do
  mcp_call $((400+i)) masc_keeper_down "$(jq -cn --arg n "bench-${i}" '{name:$n}')" 20 >/dev/null || true
done

# --- metrics: tool calls + duplicate calls from the tool_calls jsonl store ---
tool_log_dir="$MASC_BASE_PATH/.masc/tool_calls"
tool_calls=0; dup_calls=0
if [[ -d "$tool_log_dir" ]]; then
  tool_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + | jq -s 'length')"
  dup_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + \
    | jq -s 'group_by([.tool, ((.input // .arguments // {})|tostring)]) | map(select(length>1) | (length-1)) | add // 0')"
fi

jq -n \
  --arg state "$state" \
  --argjson duration_ms $(( (end_epoch - start_epoch) * 1000 )) \
  --argjson tool_calls "${tool_calls:-0}" \
  --argjson duplicate_tool_calls "${dup_calls:-0}" \
  --argjson final "${final:-{}}" \
  '{state:$state, duration_ms:$duration_ms, tool_calls:$tool_calls,
    duplicate_tool_calls:$duplicate_tool_calls, final:$final}' \
  > "$RESULT_JSON"
cat "$RESULT_JSON"
[[ "$state" == "Succeeded" ]]
