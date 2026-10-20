#!/usr/bin/env bash
# Coding report rows contain measurements made by the coding harness. Runtime
# request/attempt IDs and independent verdicts must come from their producers.
# The report reader independently checks this pass equation against status,
# verify_exit and regression_exit.

coding_eval_operation_id() {
  jq -ce '.operation_id | if type == "string" and length > 0
    then . else error("keeper admission returned no operation_id string") end'
}

evidence_row() {
  jq -cn \
    --arg case_id "$1" \
    --argjson run_index "$2" \
    --arg run_id "$3" \
    --arg provider "$4" \
    --arg model "$5" \
    --arg status "$6" \
    --argjson verify_exit "$7" \
    --argjson duration_ms "$8" \
    --argjson recorded_at "$9" \
    --argjson tool_calls "${10}" \
    --argjson input_tokens "${11}" \
    --argjson output_tokens "${12}" \
    --argjson cost_usd "${13}" \
    --argjson error "${14}" \
    --argjson regression_exit "${15}" \
    --argjson edited_source_files "${16}" \
    --argjson edited_target_files "${17}" \
    --argjson build_exit "${18}" \
    --argjson operation_id "${19}" \
    '{
      case_id: $case_id,
      run_index: $run_index,
      run_id: $run_id,
      operation_id: $operation_id,
      provider: $provider,
      model: $model,
      status: $status,
      verify_exit: $verify_exit,
      regression_exit: $regression_exit,
      edited_source_files: $edited_source_files,
      edited_target_files: $edited_target_files,
      build_exit: $build_exit,
      passed: ($status == "ok" and $verify_exit == 0
               and ($regression_exit == null or $regression_exit == 0)),
      duration_ms: $duration_ms,
      recorded_at: $recorded_at,
      tool_calls: $tool_calls,
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      cost_usd: $cost_usd,
      error: $error
    }'
}
