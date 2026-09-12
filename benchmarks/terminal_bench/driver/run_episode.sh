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
source "$BENCH/driver/gh_seed.sh"

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
  # remote_ssh preflight (keeper_sandbox_remote.perform_preflight) requires
  # the keeper root <remote_root>/<name> to already exist; the bench endpoint
  # is this same container with remote_root=/root.
  mkdir -p "/root/${k}"
  # Preflight also runs `gh auth status` with GH_CONFIG_DIR=<keeper root>/
  # .config/gh and refuses keeper_up without a GitHub identity
  # (remote_github_identity_missing); gh_seed.sh seeds hosts.yml from
  # ${GH_TOKEN} and is a no-op when it is unset.
  seed_gh_hosts "${k}"
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

# The poll must not let a client failure decide the episode. `|| true` made a
# transport error indistinguishable from "not finished yet", so a run whose
# status calls all failed sat here to the deadline and was recorded as
# Timeout — on the one field the benchmark measures. Failures are counted and
# reported as their own state instead.
state="Timeout"; final='{}'
poll_failures=0
POLL_FAILURE_LIMIT="${POLL_FAILURE_LIMIT:-10}"
deadline=$(( start_epoch + EPISODE_TIMEOUT_SEC ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  if st="$(mcp_call 300 masc_keeper_delegate_status "$(jq -cn \
    --arg op "$op_id" \
    '{target:{kind:"keeper",name:"bench-1"}, operation_id:$op}')" 30)"
  then
    poll_failures=0
  else
    poll_failures=$(( poll_failures + 1 ))
    if [[ "$poll_failures" -ge "$POLL_FAILURE_LIMIT" ]]; then
      state="PollError"
      final="$(jq -cn --argjson n "$poll_failures" \
        '{error:"delegate_status failed consecutively", failures:$n}')"
      break
    fi
    sleep "$POLL_INTERVAL_SEC"
    continue
  fi
  s="$(printf '%s' "$st" | jq -r '.state // empty' 2>/dev/null || true)"
  case "$s" in
    "") : ;;
    Succeeded|Failed|Cancelled) state="$s"; final="$st"; break ;;
    # An unmapped terminal state is surfaced under its own name rather than
    # polled until it looks like a timeout.
    *) state="$s"; final="$st"; break ;;
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
  # Guarded like the usage block below: one malformed line in the jsonl store
  # makes jq exit non-zero, and under `set -euo pipefail` an unguarded
  # assignment aborted the script here — after the episode state was known and
  # before result.json was written, so harbor recorded no result at all.
  # Counted as a stream (`jq -c . | wc -l`): every entry carries multi-KB
  # output blobs, and `jq -s` materializes all of them just to take a length.
  # Equivalent under the same guard: verified on a synthetic store — clean
  # N, malformed-mixed and empty all agree, pipefail keeps the 0-degrade.
  tool_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + | jq -c . | wc -l | tr -d ' ')" \
    || tool_calls=0
  dup_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + \
    | jq -s 'group_by([.tool, ((.input // .arguments // {})|tostring)]) | map(select(length>1) | (length-1)) | add // 0')" \
    || dup_calls=0
fi

# --- token usage: episode-summed from the agent-core trace dumps ---
# Cache creation and cache read are summed into cache_tokens for harbor's
# single n_cache_tokens field, and also reported apart. They are priced
# differently -- 2.5e-06 against 2e-07 per token for claude-sonnet-5, a factor
# of twelve -- so a cost computed from the sum is not a cost.
#
# Each .masc/traces/<session>/trace-*.json carries a cumulative top-level
# `usage` block (total_input_tokens / total_output_tokens /
# total_cache_creation_input_tokens / total_cache_read_input_tokens /
# api_calls). A session dir can hold several per-turn dumps, so keep the dump
# with the most api_calls per session, then sum across sessions. The sibling
# agent-core-snapshot-*.json repeats the same block and is excluded to avoid
# double counting. Emits null when no traces exist.
usage_json='null'
traces_dir="$MASC_BASE_PATH/.masc/traces"
if [[ -d "$traces_dir" ]]; then
  usage_json="$(find "$traces_dir" -type f -name 'trace-*.json' -print0 2>/dev/null \
    | xargs -0 jq -c '{s:(input_filename|split("/")[-2]), u:(.usage // {}), a:(.usage.api_calls // 0)}' 2>/dev/null \
    | jq -sc '
        if length == 0 then null
        else
          (group_by(.s) | map(max_by(.a) | .u)) as $us
          | { input_tokens: ($us | map(.total_input_tokens // 0) | add),
              output_tokens: ($us | map(.total_output_tokens // 0) | add),
              cache_creation_tokens:
                ($us | map(.total_cache_creation_input_tokens // 0) | add),
              cache_read_tokens:
                ($us | map(.total_cache_read_input_tokens // 0) | add),
              cache_tokens: ($us | map((.total_cache_creation_input_tokens // 0)
                                       + (.total_cache_read_input_tokens // 0)) | add) }
        end' 2>/dev/null)" || usage_json='null'
fi
if ! printf '%s' "$usage_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  usage_json='null'
fi

# Belt-and-suspenders: --argjson needs each value to be exactly one JSON text.
# A multi-line/invalid `final` (or a non-numeric counter) must degrade to a
# placeholder instead of killing the episode with jq's exit 2.
final="$(printf '%s' "$final" | jq -c 'if type=="object" then . else {} end' 2>/dev/null | tail -n 1)" || true
[[ -n "$final" ]] || final='{}'
[[ "$tool_calls" =~ ^[0-9]+$ ]] || tool_calls=0
[[ "$dup_calls" =~ ^[0-9]+$ ]] || dup_calls=0

echo "run_episode: state=$state tool_calls=$tool_calls dup=$dup_calls final_len=${#final}" >&2

# NOTE: pass `final` via --slurpfile, not --argjson: the select() keeps the
# last object if the text ever holds multiple values, and a file read keeps
# jq-1.7 (ubuntu:24.04) away from any argument-length quirks.
# Never write this as ${final:-{}}: bash closes the expansion at the first
# '}', so the default's second '}' becomes a literal suffix and corrupts the
# payload. The guard above already pins final to '{}' when empty.
final_file="$(mktemp)"
printf '%s' "$final" > "$final_file"
jq -n \
  --arg state "$state" \
  --argjson duration_ms $(( (end_epoch - start_epoch) * 1000 )) \
  --argjson tool_calls "${tool_calls:-0}" \
  --argjson duplicate_tool_calls "${dup_calls:-0}" \
  --argjson usage "$usage_json" \
  --slurpfile final_raw "$final_file" \
  '{state:$state, duration_ms:$duration_ms, tool_calls:$tool_calls,
    duplicate_tool_calls:$duplicate_tool_calls,
    input_tokens:($usage.input_tokens // null),
    output_tokens:($usage.output_tokens // null),
    cache_tokens:($usage.cache_tokens // null),
    cache_creation_tokens:($usage.cache_creation_tokens // null),
    cache_read_tokens:($usage.cache_read_tokens // null),
    final:($final_raw | map(select(type=="object")) | last // {})}' \
  > "$RESULT_JSON"
rm -f "$final_file"
cat "$RESULT_JSON"
[[ "$state" == "Succeeded" ]]
