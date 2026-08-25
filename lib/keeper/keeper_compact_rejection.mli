type compaction_rejection =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_flow_already_started
  | Exact_execution_terminal of Keeper_compaction_outcome.exact_execution_terminal
  | Invalid_compaction_plan
  | Invalid_structure of Keeper_compaction_unit.structural_error
  | No_eligible_history
  | No_reducible_boundary
  | Invalid_structural_evidence of
      Keeper_compaction_evidence.decode_error
      * Keeper_compaction_outcome.exact_execution_terminal

val compaction_rejection_to_tag : compaction_rejection -> string
val compaction_rejection_to_string : compaction_rejection -> string

val summarization_rejection :
  Keeper_compaction_llm_summarizer.summarization_failure -> compaction_rejection
