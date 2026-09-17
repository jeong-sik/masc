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
POLL_INTERVAL_SEC=10
# The episode has no deadline of its own. Harbor's agent timeout (28800s on
# every Terminal-Bench 4.0 task) is the only bound: when it fires, harbor
# cancels the agent and the agent runs collect_result.sh --interrupted, which
# leaves this mark for the loop below.
INTERRUPTED_MARK="$BENCH/episode.interrupted"

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
  # A GitHub identity only when GH_TOKEN is given (gh_seed.sh).
  seed_gh_hosts "${k}"
  mcp_call $((100+i)) masc_keeper_up "$(jq -cn \
    --arg name "$k" --arg ins "$KEEPER_INSTRUCTIONS" --arg rid "$RUNTIME_ID" \
    '{name:$name, instructions:$ins, runtime_id:$rid, activation_mode:"manual"}')" 90 >/dev/null
  curl -fsS -m 20 -X POST "http://127.0.0.1:8935/api/v1/keepers/tool-approval-mode" \
    -H "Authorization: Bearer ${MCP_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${k}\",\"mode\":\"yolo\"}" >/dev/null
done

start_epoch="$(date +%s)"
# What collect_result.sh needs to report an episode it did not watch end.
jq -n --argjson start "$start_epoch" '{start_epoch:$start, operation_id:null}' \
  > "$BENCH/episode.json"
printf '%s' "$lead_msg" > "$BENCH/episode-message.txt"
final_file="$(mktemp)"
printf '{}' > "$final_file"
submit="$(mcp_call 200 masc_keeper_msg \
  "$(jq -cn --arg name bench-1 --rawfile m "$BENCH/episode-message.txt" \
    '{name:$name, message:$m}')" 60)" || {
  sleep 5
  submit="$(mcp_call 200 masc_keeper_msg \
    "$(jq -cn --arg name bench-1 --rawfile m "$BENCH/episode-message.txt" \
      '{name:$name, message:$m}')" 60)" || {
    bash "$BENCH/driver/collect_result.sh" "$RESULT_JSON" Error "$final_file"
    exit 1
  }
}
op_id="$(printf '%s' "$submit" | jq -r '.operation_id // empty')"
[[ -n "$op_id" ]] || { echo "keeper_msg returned no operation_id: $submit" >&2; exit 1; }
jq -n --argjson start "$start_epoch" --arg op "$op_id" \
  '{start_epoch:$start, operation_id:$op}' > "$BENCH/episode.json"

# The poll must not let a client failure decide the episode. `|| true` made a
# transport error indistinguishable from "not finished yet". Failures are
# counted and reported as their own state instead.
state=""; final='{}'
poll_failures=0
POLL_FAILURE_LIMIT="${POLL_FAILURE_LIMIT:-10}"
while [[ -z "$state" ]]; do
  # Harbor's time limit already ended this episode and collect_result.sh has
  # reported it; a second result.json would overwrite that report.
  [[ -e "$INTERRUPTED_MARK" ]] && exit 1
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
    # polled until harbor's time limit ends the episode.
    *) state="$s"; final="$st"; break ;;
  esac
  sleep "$POLL_INTERVAL_SEC"
done
[[ -e "$INTERRUPTED_MARK" ]] && exit 1

printf '%s' "$final" > "$final_file"
bash "$BENCH/driver/collect_result.sh" "$RESULT_JSON" "$state" "$final_file"
rm -f "$final_file"
[[ "$state" == "Succeeded" ]]
