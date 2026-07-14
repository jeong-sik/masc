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
val runtime_rotation_outcome_to_string : runtime_rotation_outcome -> string
type runtime_outcome =
    Runtime_passed_to_next_model
  | Runtime_completed
  | Runtime_failed
  | Runtime_not_observed
  | Runtime_not_dispatched
val runtime_outcome_to_string : runtime_outcome -> string
type completion_contract_result =
    Completion_observation_unknown
  | Completion_not_dispatched
  | Completion_no_visible_output
  | Completion_response_observed
  | Completion_tool_execution_observed
val completion_contract_result_to_string : completion_contract_result -> string
val completion_contract_result_of_string : string -> completion_contract_result option
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
    (** World-observation signal captured at turn time. It is independent of
        completion evidence and does not authorize or block the turn. *)
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

(** Project the runtime-stop axis into the receipt terminal-reason field.
    Runtime [Completed] and observational execution-limit stops emit canonical
    [Keeper_turn_disposition.Success]. The independent [stop_reason] field keeps
    each observation without turning it into a MASC lifecycle gate. *)
val receipt_terminal_reason_code_of_stop_reason : Runtime_agent.stop_reason -> string
val sandbox_kind_of_meta :
  Keeper_meta_contract.keeper_meta -> Keeper_types_profile_sandbox.sandbox_profile
val list_json : 'a list -> [> `List of [> `String of 'a ] list ]
val string_opt_json : 'a option -> [> `Null | `String of 'a ]
