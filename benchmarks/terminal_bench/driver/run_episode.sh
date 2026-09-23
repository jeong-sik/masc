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
# shellcheck source-path=SCRIPTDIR source=endpoint_account.sh
source "$BENCH/driver/endpoint_account.sh"

INSTRUCTION_FILE="$1"
RESULT_JSON="$2"
KEEPER_COUNT="${KEEPER_COUNT:-1}"
RUNTIME_ID="${BENCH_RUNTIME_ID:?BENCH_RUNTIME_ID required (e.g. anthropic.claude-fable-5-1)}"
POLL_INTERVAL_SEC=10
# The episode has no deadline of its own. Harbor's agent timeout (28800s on
# every Terminal-Bench 4.0 task) is the only bound: when it fires, harbor
# cancels the agent and the agent runs collect_result.sh --interrupted, which
# leaves this mark for the loop below.
INTERRUPTED_MARK="$BENCH/episode.interrupted"
EPISODE_PID_FILE="$BENCH/episode.pid"

# A container can run more than one episode (harbor multi-step trials reuse the
# environment). What the previous one left must not end or answer for this one.
rm -f "$INTERRUPTED_MARK" "$BENCH/episode.json" "$RESULT_JSON"
# collect_result.sh --interrupted ends this script by pid: pkill is not in
# every task image (python:*-slim ships without procps).
printf '%s\n' "$$" > "$EPISODE_PID_FILE"
final_file="$(mktemp)"
setup_error_file="$(mktemp)"
trap 'rm -f "$final_file" "$setup_error_file"' EXIT

# report_setup_failure <state> <keeper>: result.json for a keeper that could
# not be brought up, then exit 1.
report_setup_failure() {
  jq -n --arg keeper "$2" --rawfile error "$setup_error_file" \
    '{keeper:$keeper, error:$error}' > "$final_file"
  bash "$BENCH/driver/collect_result.sh" "$RESULT_JSON" "$1" "$final_file"
  exit 1
}

KEEPER_INSTRUCTIONS="You are an autonomous engineering agent inside a Linux container. \
Complete the task by running shell commands (your tool calls execute in this container). \
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
  # is this same container, and the keeper's commands run there as the image's
  # user (endpoint_account.sh).
  bench_keeper_root "${k}"
  # A GitHub identity only when GH_TOKEN is given (gh_seed.sh).
  seed_gh_hosts "${k}"
  # A keeper that does not come up is the episode's result, not a reason to
  # leave none: the failure is reported through collect_result.sh with the
  # server's own words.
  if ! mcp_call $((100+i)) masc_keeper_up "$(jq -cn \
      --arg name "$k" --arg ins "$KEEPER_INSTRUCTIONS" --arg rid "$RUNTIME_ID" \
      '{name:$name, instructions:$ins, runtime_id:$rid, activation_mode:"manual"}')" 90 \
      >/dev/null 2>"$setup_error_file"; then
    report_setup_failure KeeperUpFailed "$k"
  fi
  # Not `curl -f`: it drops the response body on an HTTP error, and the body
  # is the server's reason.
  approval_status="$(curl -sS -m 20 -o "$setup_error_file" -w '%{http_code}' \
      -X POST "http://127.0.0.1:8935/api/v1/keepers/tool-approval-mode" \
      -H "Authorization: Bearer ${MCP_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${k}\",\"mode\":\"yolo\"}" 2>>"$setup_error_file")" \
    || approval_status="000"
  if [[ "$approval_status" != 2?? ]]; then
    printf '\nHTTP %s\n' "$approval_status" >> "$setup_error_file"
    report_setup_failure ApprovalModeFailed "$k"
  fi
done

start_epoch="$(date +%s)"
# What collect_result.sh needs to report an episode it did not watch end.
jq -n --argjson start "$start_epoch" '{start_epoch:$start, operation_id:null}' \
  > "$BENCH/episode.json"
printf '%s' "$lead_msg" > "$BENCH/episode-message.txt"
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
if [[ -z "$op_id" ]]; then
  echo "keeper_msg returned no operation_id: $submit" >&2
  printf '%s' "$submit" > "$final_file"
  bash "$BENCH/driver/collect_result.sh" "$RESULT_JSON" NoOperationId "$final_file"
  exit 1
fi
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
    :
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
  # The operation state is Keeper_chat_operation.state, a closed set encoded
  # by name (keeper_chat_operation.ml): Queued and Running are still working,
  # the other three are terminal. A response with no state is a failed poll.
  # A name outside the set is a state this driver has not been taught, and is
  # reported under that name rather than polled until the time limit.
  s="$(printf '%s' "$st" | jq -r '.state // empty' 2>/dev/null || true)"
  case "$s" in
    Queued|Running) poll_failures=0 ;;
    Succeeded|Failed|Cancelled) state="$s"; final="$st"; break ;;
    "")
      poll_failures=$(( poll_failures + 1 ))
      if [[ "$poll_failures" -ge "$POLL_FAILURE_LIMIT" ]]; then
        state="PollError"
        final="$(jq -cn --arg last "$st" --argjson n "$poll_failures" \
          '{error:"delegate_status carried no state", failures:$n, last:$last}')"
        break
      fi
      ;;
    *) state="$s"; final="$st"; break ;;
  esac
  sleep "$POLL_INTERVAL_SEC"
done
[[ -e "$INTERRUPTED_MARK" ]] && exit 1

printf '%s' "$final" > "$final_file"
bash "$BENCH/driver/collect_result.sh" "$RESULT_JSON" "$state" "$final_file"
[[ "$state" == "Succeeded" ]]
