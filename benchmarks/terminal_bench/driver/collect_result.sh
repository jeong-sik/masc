#!/usr/bin/env bash
# usage: collect_result.sh <result-json-path> <state> <final-json-file>
#        collect_result.sh <result-json-path> --interrupted
#
# Stops the episode's keepers and writes result.json: the episode state, tool
# call counts and token usage.
#
# Two callers. run_episode.sh calls it with the terminal state it polled. The
# harbor agent calls it with --interrupted when harbor's agent timeout
# cancelled the episode: harbor never tells an installed agent its timeout, and
# the episode has no deadline of its own, so the cancellation is the only
# signal that the time is up. That path asks the server for the delegate state
# once, as it stands, and records it under its own name.
#
# Both paths stop the keepers and wait until they are gone before writing
# result.json. Harbor downloads the task's artifacts while the agent environment
# is still running, and a keeper still working past the time limit would keep
# writing into them. keeper_down only submits the shutdown, so the wait is what
# makes it true; a keeper that is still there when the wait ends is recorded as
# keepers_stopped=false rather than assumed gone.
set -euo pipefail

BENCH=/opt/masc-bench
export MASC_BASE_PATH=$BENCH/base

RESULT_JSON="$1"
MODE="$2"
KEEPER_COUNT="${KEEPER_COUNT:-1}"
EPISODE_JSON="$BENCH/episode.json"
INTERRUPTED_MARK="$BENCH/episode.interrupted"
# The wait for stopped keepers is bounded so that result.json is written inside
# the agent's recovery exec (RESULT_RECOVERY_TIMEOUT_SEC, 600s, in
# agents/masc_agent.py). A shutdown normally completes within a few polls.
KEEPER_STOP_POLL_SEC=2
KEEPER_STOP_POLLS=60

if [[ "$MODE" == "--interrupted" ]]; then
  # run_episode.sh is still running after harbor dropped its exec. It may be
  # polling, or still bringing keepers up and submitting the task when the time
  # limit lands early. Mark the episode as reported and end that script before
  # anything else, so it neither starts work after this point nor writes a
  # second result.json over this one.
  touch "$INTERRUPTED_MARK"
  episode_pid="$(cat "$BENCH/episode.pid" 2>/dev/null || true)"
  [[ "$episode_pid" =~ ^[0-9]+$ ]] && kill "$episode_pid" 2>/dev/null || true
fi

MCP_TOKEN="$(cat "$BENCH/token")"
export MCP_TOKEN
source "$BENCH/driver/mcp.sh"

server_up=0
if mcp_init 2>/dev/null; then server_up=1; fi

interrupted=false
final='{}'
if [[ "$MODE" == "--interrupted" ]]; then
  interrupted=true
  op_id="$(jq -r '.operation_id // empty' "$EPISODE_JSON" 2>/dev/null || true)"
  if [[ -z "$op_id" ]]; then
    state="NotSubmitted"
  elif [[ "$server_up" -ne 1 ]]; then
    state="StatusUnavailable"
  elif st="$(mcp_call 300 masc_keeper_delegate_status "$(jq -cn \
      --arg op "$op_id" \
      '{target:{kind:"keeper",name:"bench-1"}, operation_id:$op}')" 30)"; then
    state="$(printf '%s' "$st" | jq -r '.state // empty' 2>/dev/null || true)"
    [[ -n "$state" ]] || state="StatusUnavailable"
    final="$st"
  else
    state="StatusUnavailable"
  fi
else
  state="$MODE"
  final="$(cat "$3")"
fi

# keeper_down answers already_absent=true once the keeper has no lane, no
# shutdown in progress and no metadata; remove_meta makes the completed
# shutdown reach that answer. Asked again each poll for every keeper still
# present.
keepers_stopped=false
if [[ "$server_up" -eq 1 ]]; then
  remaining=""
  for i in $(seq 1 "${KEEPER_COUNT}"); do remaining="${remaining} bench-${i}"; done
  poll=0
  while [[ -n "${remaining// /}" && "$poll" -lt "$KEEPER_STOP_POLLS" ]]; do
    still=""
    for k in ${remaining}; do
      down="$(mcp_call $((400+poll)) masc_keeper_down \
        "$(jq -cn --arg n "$k" '{name:$n, remove_meta:true}')" 20 2>/dev/null)" || down='{}'
      printf '%s' "$down" | jq -e '.already_absent == true' >/dev/null 2>&1 \
        || still="${still} ${k}"
    done
    remaining="${still}"
    poll=$((poll + 1))
    [[ -n "${remaining// /}" ]] && sleep "$KEEPER_STOP_POLL_SEC"
  done
  [[ -z "${remaining// /}" ]] && keepers_stopped=true
fi

start_epoch="$(jq -r '.start_epoch // empty' "$EPISODE_JSON" 2>/dev/null || true)"
if [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
  duration_ms=$(( ($(date +%s) - start_epoch) * 1000 ))
else
  duration_ms=null
fi

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
  # Invariant (measured 2026-09-14): the count must stay a stream — swapping
  # in `jq -s 'length'` re-materializes every multi-KB blob per episode.
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

echo "collect_result: state=$state interrupted=$interrupted keepers_stopped=$keepers_stopped tool_calls=$tool_calls dup=$dup_calls final_len=${#final}" >&2

# NOTE: pass `final` via --slurpfile, not --argjson: the select() keeps the
# last object if the text ever holds multiple values, and a file read keeps
# jq-1.7 (ubuntu:24.04) away from any argument-length quirks.
# Never write this as ${final:-{}}: bash closes the expansion at the first
# '}', so the default's second '}' becomes a literal suffix and corrupts the
# payload. The guard above already pins final to '{}' when empty.
final_file="$(mktemp)"
printf '%s' "$final" > "$final_file"
# Written beside the target and renamed into place: the agent reads this file
# right after the script returns, and a reader must never see half of it.
tmp_result="$(mktemp "${RESULT_JSON}.XXXXXX")"
# A report from run_episode.sh that was already running when harbor's time
# limit ended the episode (its parent script is killed, this child is not)
# must not replace the interrupted report.
episode_reported_interrupted() {
  [[ "$MODE" != "--interrupted" && -e "$INTERRUPTED_MARK" ]]
}
jq -n \
  --arg state "$state" \
  --argjson interrupted "$interrupted" \
  --argjson keepers_stopped "$keepers_stopped" \
  --argjson duration_ms "$duration_ms" \
  --argjson tool_calls "${tool_calls:-0}" \
  --argjson duplicate_tool_calls "${dup_calls:-0}" \
  --argjson usage "$usage_json" \
  --slurpfile final_raw "$final_file" \
  '{state:$state, interrupted:$interrupted, keepers_stopped:$keepers_stopped,
    duration_ms:$duration_ms,
    tool_calls:$tool_calls, duplicate_tool_calls:$duplicate_tool_calls,
    input_tokens:($usage.input_tokens // null),
    output_tokens:($usage.output_tokens // null),
    cache_tokens:($usage.cache_tokens // null),
    cache_creation_tokens:($usage.cache_creation_tokens // null),
    cache_read_tokens:($usage.cache_read_tokens // null),
    final:($final_raw | map(select(type=="object")) | last // {})}' \
  > "$tmp_result"
if episode_reported_interrupted; then
  rm -f "$tmp_result" "$final_file"
  exit 1
fi
mv "$tmp_result" "$RESULT_JSON"
rm -f "$final_file"
cat "$RESULT_JSON"
