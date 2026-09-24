# shellcheck shell=bash
# Which runtime answered each keeper turn of an episode.
#
# A failover arm (arm l) routes its keeper through a lane of several candidate
# models, and a turn is answered by whichever candidate the lane reached. The
# keeper's decision log records every turn as one `event: "turn"` row. Its
# `outcome` is what the turn ended as, and provider_context.executed_runtime_id
# is the runtime the lane walk reported:
#
# - success, checkpoint, input_required (keeper_unified_turn_success.ml
#   decision_outcome_to_label): the model answered, and the id is the
#   candidate that answered.
# - error (keeper_unified_turn.ml): the turn failed. The id is the last
#   candidate the walk dispatched, which failed, or null when no candidate was
#   dispatched (masc#35043).
#
# The log is <keeper>.decisions.jsonl in the keepers runtime directory, rotated
# to <keeper>.decisions.jsonl.<n> (keeper_runtime_root_entry.ml).
#
# bench_answered_by_json <keepers runtime dir>: prints one JSON object,
#   {"answered_by": {"<runtime id>": <turns>, ...},
#    "failed_on": {"<runtime id>": <turns>, ...},
#    "turns_unanswered": <turns>}
# where turns_unanswered counts the failed turns no candidate was dispatched
# for. It prints `null` when the directory holds no decision log, because an
# episode that recorded nothing was not measured and must not read as zero
# turns. A turn row of any other shape (no provider_context, no
# executed_runtime_id key, an outcome not listed above, an answered turn that
# names no runtime) fails the function with a non-zero exit, so the caller can
# record null instead of a count that silently left rows out.
#
# A turn cancelled mid-flight (harbor's timeout, keeper_down) re-raises the
# cancellation before its row is appended, so it is in no count.
bench_answered_by_json() {
  local dir="$1"
  local file turns
  local -a logs=()
  [[ -d "${dir}" ]] || { printf 'null\n'; return 0; }
  while IFS= read -r file; do
    logs+=("${file}")
  done < <(find "${dir}" -maxdepth 1 -type f \
    \( -name '*.decisions.jsonl' -o -name '*.decisions.jsonl.[0-9]*' \) | sort)
  if [[ "${#logs[@]}" -eq 0 ]]; then
    printf 'null\n'
    return 0
  fi
  # Two steps rather than one pipeline: the first jq's refusal must fail the
  # function whether or not the caller runs under pipefail.
  turns="$(jq -c '
      select(.event == "turn")
      | (.provider_context
         | if type == "object" and has("executed_runtime_id") then .executed_runtime_id
           else error("turn row without provider_context.executed_runtime_id") end
         | if . == null or type == "string" then .
           else error("executed_runtime_id is neither a string nor null") end) as $rid
      | if .outcome == "success" or .outcome == "checkpoint"
           or .outcome == "input_required" then
          (if $rid == null then error("an answered turn names no runtime")
           else {answered: $rid} end)
        elif .outcome == "error" then {failed: $rid}
        else error("unknown turn outcome \(.outcome)") end' \
    "${logs[@]}")" || return 1
  printf '%s' "${turns}" | jq -sc '
      def counts(f): map(f | select(. != null)) | group_by(.)
                     | map({key: .[0], value: length}) | from_entries;
      { answered_by: counts(.answered),
        failed_on: counts(.failed),
        turns_unanswered: (map(select(has("failed") and .failed == null)) | length) }'
}
