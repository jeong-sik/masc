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
type tool_surface = {
  turn_lane : Keeper_agent_tool_surface.turn_lane;
}
type runtime_rotation_outcome =
    Rotation_setup_failed
  | Rotation_retry_scheduled
  | Rotation_slot_phase_exhausted
val runtime_rotation_outcome_to_string : runtime_rotation_outcome -> string
type runtime_outcome =
    Runtime_passed_to_next_model
  | Runtime_completed
  | Runtime_failed
  | Runtime_not_observed
  | Runtime_not_dispatched
val runtime_outcome_to_string : runtime_outcome -> string
type completion_contract_result =
    Contract_unknown
  | Contract_not_dispatched
  | Contract_violated
  | Contract_surface_mismatch
  | Contract_no_capable_provider
  | Contract_claim_only_after_owned_task
  | Contract_needs_execution_progress
  | Contract_passive_only
  | Contract_satisfied_completion
  | Contract_satisfied_execution
val completion_contract_result_to_string : completion_contract_result -> string
val completion_contract_result_of_string : string -> completion_contract_result option
val completion_contract_result_requires_attention : completion_contract_result -> bool
val encode_tool_list : string list -> string
val encode_contract_violation_reason :
  called_tools:string list ->
  satisfying_tools:string list -> string -> string
val decode_tool_list : string -> string list option
val decode_contract_violation_reason :
  string -> (string * string list * string list) option
type runtime_rotation_attempt = {
  from_runtime : string;
  to_runtime : string;
  reason : Keeper_error_classify.degraded_retry_reason;
  outcome : runtime_rotation_outcome;
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
  oas_internal_runtime_disabled : bool;
  current_task_id : string option;
  goal_ids : string list;
  outcome : outcome_kind;
  terminal_reason_code : string;
  response_text_present : bool;
  model_used : string option;
  completion_contract_result : completion_contract_result;
  actionable_signal : Keeper_contract_classifier.actionable_signal option;
    (** Root B (#22710): world-observation actionable signal captured at turn
        time, consumed by [operator_disposition]. Replaces the [goal_ids = []]
        proxy in [passive_only_without_work_scope]. [None] when no world
        observation was threaded (disposition falls back to broadcast-required;
        conservative, never silently suppressed). *)
  tool_surface : tool_surface;
  sandbox_kind : Keeper_types_profile_sandbox.sandbox_profile;
  sandbox_root : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode;
  runtime_id : string;
  runtime_selected_model : string option;
  runtime_attempt_count : int;
  runtime_fallback_applied : bool;
  runtime_outcome : runtime_outcome;
  oas_internal_runtime_allowed : bool;
  degraded_retry_applied : bool;
  degraded_retry_runtime : string option;
  fallback_reason :
    Keeper_error_classify.degraded_retry_reason option;
  runtime_rotation_attempts : runtime_rotation_attempt list;
  stop_reason : Runtime_agent.stop_reason option;
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
val stop_reason_to_string : Runtime_agent.stop_reason -> string
val enrich_contract_violation_reason : t -> string
val sandbox_kind_of_meta :
  Keeper_meta_contract.keeper_meta -> Keeper_types_profile_sandbox.sandbox_profile
val list_json : 'a list -> [> `List of [> `String of 'a ] list ]
val string_opt_json : 'a option -> [> `Null | `String of 'a ]
