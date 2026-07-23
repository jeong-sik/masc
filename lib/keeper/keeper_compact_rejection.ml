type compaction_rejection =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_failed_before_dispatch
  | Exact_execution_terminal of Keeper_event_queue_state.exact_execution_terminal
  | Invalid_compaction_plan
  | Invalid_structure of Keeper_compaction_unit.structural_error
  | No_eligible_history
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Invalid_structural_evidence of
      Keeper_compaction_evidence.decode_error
      * Keeper_event_queue_state.exact_execution_terminal

let compaction_rejection_to_tag = function
  | Exact_lane_unconfigured -> "exact_lane_unconfigured"
  | Exact_target_selection_failed -> "exact_target_selection_failed"
  | Exact_admission_failed -> "exact_admission_failed"
  | Exact_attempt_start_failed -> "exact_attempt_start_failed"
  | Exact_execution_context_unavailable -> "exact_execution_context_unavailable"
  | Exact_execution_failed_before_dispatch -> "exact_execution_failed_before_dispatch"
  | Exact_execution_terminal terminal ->
    Keeper_event_queue_state.exact_execution_terminal_cause_label terminal.cause
  | Invalid_compaction_plan -> "invalid_compaction_plan"
  | Invalid_structure error ->
    "invalid_structure:" ^ Keeper_compaction_unit.show_structural_error error
  | No_eligible_history -> "no_eligible_history"
  | Structurally_unchanged -> "structurally_unchanged"
  | Checkpoint_not_reduced -> "checkpoint_not_reduced"
  | Invalid_structural_evidence _ -> "invalid_structural_evidence"
;;

let compaction_rejection_to_string = function
  | Invalid_structural_evidence (error, terminal) ->
    compaction_rejection_to_tag (Invalid_structural_evidence (error, terminal))
    ^ ":"
    ^ Keeper_compaction_evidence.decode_error_to_string error
    ^ ":"
    ^ Keeper_event_queue_state.exact_execution_terminal_to_string terminal
  | Exact_execution_terminal terminal ->
    Keeper_event_queue_state.exact_execution_terminal_to_string terminal
  | reason -> compaction_rejection_to_tag reason
;;

let exact_terminal_of_observation cause
      (observation : Keeper_compaction_llm_summarizer.attempt_observation) =
  Keeper_event_queue_state.
    { cause; slot_id = observation.slot_id; call_id = observation.call_id }
;;

let summarization_rejection = function
  | Keeper_compaction_llm_summarizer.Exact_lane_unconfigured ->
    Exact_lane_unconfigured
  | Keeper_compaction_llm_summarizer.Exact_target_selection_failed ->
    Exact_target_selection_failed
  | Keeper_compaction_llm_summarizer.Exact_admission_failed -> Exact_admission_failed
  | Keeper_compaction_llm_summarizer.Exact_attempt_start_failed _ ->
    Exact_attempt_start_failed
  | Keeper_compaction_llm_summarizer.Exact_execution_context_unavailable ->
    Exact_execution_context_unavailable
  | Keeper_compaction_llm_summarizer.Exact_execution_failed_before_dispatch ->
    Exact_execution_failed_before_dispatch
  | Keeper_compaction_llm_summarizer.Exact_execution_failed_after_dispatch observation ->
    Exact_execution_terminal
      (exact_terminal_of_observation Execution_failed_after_dispatch observation)
  | Keeper_compaction_llm_summarizer.Exact_attempt_already_started observation ->
    Exact_execution_terminal
      (exact_terminal_of_observation Attempt_already_started observation)
  | Keeper_compaction_llm_summarizer.Exact_execution_cancelled_after_dispatch observation ->
    Exact_execution_terminal
      (exact_terminal_of_observation Execution_cancelled_after_dispatch observation)
  | Keeper_compaction_llm_summarizer.Exact_execution_provenance_mismatch observation ->
    Exact_execution_terminal
      (exact_terminal_of_observation Execution_provenance_mismatch observation)
  | Keeper_compaction_llm_summarizer.Invalid_plan -> Invalid_compaction_plan
  | Keeper_compaction_llm_summarizer.Invalid_plan_after_dispatch observation ->
    Exact_execution_terminal
      (exact_terminal_of_observation Domain_invalid_output observation)
;;
