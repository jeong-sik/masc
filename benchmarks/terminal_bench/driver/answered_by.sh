# shellcheck shell=bash
# Which runtime answered each keeper turn of an episode.
#
# A failover arm (arm l) routes its keeper through a lane of several candidate
# models, and a turn is answered by whichever candidate the lane reached. The
# keeper's decision log records that answerer on every `turn` row as
# provider_context.executed_runtime_id, and records null when the turn failed
# before any candidate reported in (keeper_unified_metrics_json_support.ml
# provider_context_json, masc#35043). The log is <keeper>.decisions.jsonl in
# the keepers runtime directory, rotated to <keeper>.decisions.jsonl.<n>
# (keeper_runtime_root_entry.ml).
#
# bench_answered_by_json <keepers runtime dir>: prints one JSON object,
#   {"answered_by": {"<runtime id>": <turns>, ...}, "turns_unanswered": <turns>}
# or `null` when the directory holds no decision log, because an episode that
# recorded nothing was not measured and must not read as zero turns. A row that
# does not have this shape fails the function (non-zero exit), so the caller can
# record null instead of a count that silently left rows out.
bench_answered_by_json() {
  local dir="$1"
  local file answerers
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
  answerers="$(jq -c '
      select(.event == "turn")
      | .provider_context
      | if type != "object" then error("turn row without provider_context")
        else .executed_runtime_id end
      | if . == null or type == "string" then .
        else error("executed_runtime_id is neither a string nor null") end' \
    "${logs[@]}")" || return 1
  printf '%s' "${answerers}" | jq -sc '{
      answered_by: (map(select(. != null)) | group_by(.)
                    | map({key: .[0], value: length}) | from_entries),
      turns_unanswered: (map(select(. == null)) | length)}'
}
