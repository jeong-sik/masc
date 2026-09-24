# shellcheck shell=bash
# What the keeper's tool calls came to over an episode, per tool.
#
# The tool-call ledger (.masc/tool_calls/<yyyy-mm>/<dd>.jsonl) holds more than
# calls. keeper_tool_call_log.ml writes record_kind and tool on every row.
# "tool_call" is one tool execution: a model's call, or one step a composition
# ran, which keeper_tool_composition_surface.ml writes as its own row.
# "composition_run" summarizes a run whose steps are already rows, and
# "lifecycle_event" marks what happened around a call. Only tool_call rows
# are counted.
#
# A call failed when its disposition is "failed", or, on a row with no
# disposition, when its wire_outcome is "error". A wire_outcome of "unknown"
# is not a failure. This is the repository's rule
# (Tool_result.recorded_call_outcome). The dashboard
# (dashboard_http_tool_quality.ml) applies the same rule but also counts
# composition_run rows, so a trial that ran compositions shows one call per
# run fewer here than there.
#
# bench_tool_outcomes_json <tool_calls dir>: prints one JSON object,
#   {"tool_calls": <n>, "failed_tool_calls": <n>,
#    "by_tool": [{"tool": <name>, "calls": <n>, "failed": <n>,
#                 "result_bytes": <n>, "top_failure": <line or null>}, ...]}
# with by_tool ordered by failures, then calls, then name. top_failure is the
# most common output among a tool's failed calls, its line breaks shown as
# " / " and cut to 200 characters, so a trial that lost turns to one refusal
# names it. It prints `null` when the
# directory holds no ledger, because an episode that recorded nothing was not
# measured and must not read as zero calls. A line that is not a JSON object,
# a row whose record_kind is missing or none of the three, or a call row with
# no tool or with neither disposition nor wire_outcome, fails the function
# with a non-zero exit, so the caller can record null instead of a count that
# silently left rows out.
bench_tool_outcomes_json() {
  local dir="$1"
  local file calls
  local -a logs=()
  [[ -d "${dir}" ]] || { printf 'null\n'; return 0; }
  while IFS= read -r file; do
    logs+=("${file}")
  done < <(find "${dir}" -type f -name '*.jsonl' | sort)
  if [[ "${#logs[@]}" -eq 0 ]]; then
    printf 'null\n'
    return 0
  fi
  # Two steps rather than one pipeline: the first jq's refusal must fail the
  # function whether or not the caller runs under pipefail.
  calls="$(jq -c '
      if type != "object" then error("a ledger line is not a JSON object") else . end
      | (.record_kind as $kind
         | if $kind == "tool_call" then .
           elif $kind == "composition_run" or $kind == "lifecycle_event" then empty
           else error("a ledger row has record_kind \($kind | tojson)") end)
      | (if (.tool | type) == "string" then . else error("a call row names no tool") end)
      | (if has("disposition") and .disposition != null then .disposition == "failed"
         elif has("wire_outcome") and .wire_outcome != null then .wire_outcome == "error"
         else error("a call row names neither disposition nor wire_outcome") end) as $failed
      | {tool: .tool,
         failed: $failed,
         bytes: (if (.result_bytes | type) == "number" then .result_bytes else 0 end),
         first: (if $failed then
                   (.output | if type == "string" then . else tojson end
                    | gsub("\\s*\n\\s*"; " / ") | .[0:200])
                 else null end)}
    ' "${logs[@]}")" || return 1
  printf '%s\n' "${calls}" | jq -s -c '
    {tool_calls: length,
     failed_tool_calls: (map(select(.failed)) | length),
     by_tool: (group_by(.tool)
               | map({tool: .[0].tool,
                      calls: length,
                      failed: (map(select(.failed)) | length),
                      result_bytes: (map(.bytes) | add),
                      top_failure: (map(select(.failed) | .first)
                                    | if length == 0 then null
                                      else group_by(.) | max_by(length) | .[0] end)})
               | sort_by(-.failed, -.calls, .tool))}'
}
