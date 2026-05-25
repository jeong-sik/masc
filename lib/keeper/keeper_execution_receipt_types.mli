type outcome_kind =
    Keeper_execution_receipt_outcome_kind.outcome_kind
val outcome_kind_to_string :
  Keeper_execution_receipt_outcome_kind.outcome_kind -> string
val outcome_kind_to_tla_receipt :
  Keeper_execution_receipt_outcome_kind.outcome_kind -> string
val outcome_kind_of_string :
  string ->
  Keeper_execution_receipt_outcome_kind.outcome_kind option
val outcome_kind_is_terminal_success :
  Keeper_execution_receipt_outcome_kind.outcome_kind -> bool
type error_kind = Error_kind of string
val error_kind_of_string : string -> error_kind
val error_kind_to_string : error_kind -> string
type receipt_authority_violation = { outcome : string; turn_state : string; }
val assert_receipt_authoritative :
  outcome:[< `Cancelled | `Error | `Ok | `Skipped ] ->
  turn_state:string -> (unit, receipt_authority_violation) result
type tool_requirement = Keeper_agent_tool_surface.tool_requirement
type tool_surface = {
  turn_lane : Keeper_agent_tool_surface.turn_lane;
  tool_surface_class : Keeper_agent_tool_surface.tool_surface_class;
  tool_requirement : Keeper_agent_tool_surface.tool_requirement;
  visible_tool_count : int;
  tool_gate_enabled : bool;
  tool_surface_fallback_used : bool;
  required_tools : string list;
  required_tool_candidates : string list;
  missing_required_tools : string list;
  materialized_tools : string list;
}
type slot_release_phase =
    Retry_setup_failed
  | Retry_scheduled
  | Retry_budget_exhausted
  | Productive_phase_exhausted
val to_tla_symbol : slot_release_phase -> string
val all_symbols : string list
val all_states : slot_release_phase list
val terminal_symbols : 'a list
val active_symbols : 'a list
val idle_symbols : 'a list
val is_terminal : slot_release_phase -> bool
val is_active : slot_release_phase -> bool
val is_idle : slot_release_phase -> bool
val slot_release_phase_to_string : slot_release_phase -> string
type cascade_rotation_outcome =
    Rotation_setup_failed
  | Rotation_retry_scheduled
  | Rotation_budget_exhausted
  | Rotation_slot_phase_exhausted
val cascade_rotation_outcome_to_string : cascade_rotation_outcome -> string
type cascade_outcome =
    Cascade_passed_to_next_model
  | Cascade_completed
  | Cascade_not_observed
  | Cascade_not_dispatched
val cascade_outcome_to_string : cascade_outcome -> string
type tool_contract_result =
    Contract_unknown
  | Contract_not_dispatched
  | Contract_violated
  | Contract_tool_surface_mismatch
  | Contract_no_tool_capable_provider
  | Contract_missing_required_tool_use
  | Contract_claim_only_after_owned_task
  | Contract_needs_execution_progress
  | Contract_passive_only
  | Contract_satisfied_completion
  | Contract_satisfied_execution
val tool_contract_result_to_string : tool_contract_result -> string
val tool_contract_result_of_contract_status :
  Keeper_contract_classifier.contract_status -> tool_contract_result
val encode_tool_list : string list -> string
val encode_contract_violation_reason :
  called_tools:string list ->
  satisfying_tools:string list -> string -> string
val decode_tool_list : string -> string list option
val decode_contract_violation_reason :
  string -> (string * string list * string list) option
type cascade_rotation_attempt = {
  from_cascade : Cascade_name.t;
  to_cascade : Cascade_name.t;
  reason : Keeper_error_classify.degraded_retry_reason;
  outcome : cascade_rotation_outcome;
  slot_release_at_phase : slot_release_phase option;
  productive_phase_elapsed_ms : int option;
  retry_phase_elapsed_ms : int option;
  error_kind : error_kind option;
  error_message : string option;
  recorded_at : string;
}
type t = {
  keeper_name : string;
  agent_name : string;
  trace_id : string;
  generation : int;
  turn_count : int option;
  oas_turn_count : int option;
  oas_dispatch_mode : string option;
  oas_internal_cascade_disabled : bool;
  current_task_id : string option;
  goal_ids : string list;
  outcome : outcome_kind;
  terminal_reason_code : string;
  response_text_present : bool;
  model_used : string option;
  requested_tools : string list;
  reported_tools : string list;
  observed_tools : string list;
  canonical_tools : string list;
  unexpected_tools : string list;
  tools_used : string list;
  tool_contract_result : tool_contract_result;
  tool_surface : tool_surface;
  sandbox_kind : Keeper_types.sandbox_profile;
  sandbox_root : string option;
  network_mode : Keeper_types.network_mode;
  approval_profile : string option;
  approval_profile_derived : bool;
  cascade_name : Cascade_name.t;
  cascade_selected_model : string option;
  cascade_attempt_count : int;
  cascade_fallback_applied : bool;
  cascade_outcome : cascade_outcome;
  oas_internal_cascade_allowed : bool;
  degraded_retry_applied : bool;
  degraded_retry_cascade : Cascade_name.t option;
  fallback_reason :
    Keeper_error_classify.degraded_retry_reason option;
  cascade_rotation_attempts : cascade_rotation_attempt list;
  stop_reason : Cascade_runner.stop_reason option;
  error_kind : error_kind option;
  error_message : string option;
  started_at : string;
  ended_at : string;
  extra_system_context_digest : string option;
  extra_system_context_injected_size : int option;
  extra_system_context_computed_size : int option;
  pre_dispatch_compacted : bool;
  pre_dispatch_compaction_trigger : string option;
  pre_dispatch_compaction_before_tokens : int option;
  pre_dispatch_compaction_after_tokens : int option;
}
val stop_reason_to_string : Cascade_runner.stop_reason -> string
val enrich_contract_violation_reason : t -> string
val sandbox_kind_of_meta :
  Keeper_types.keeper_meta -> Keeper_types.sandbox_profile
val list_json : 'a list -> [> `List of [> `String of 'a ] list ]
val string_opt_json : 'a option -> [> `Null | `String of 'a ]
