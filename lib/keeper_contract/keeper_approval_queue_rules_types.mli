(** Approval queue rule types, conversions, and JSON serialization. *)

type risk_level =
  | Low
  | Medium
  | High
  | Critical

type suggested_option =
  { label : string
  ; rationale : string
  ; estimated_risk_delta : risk_level option
  }

type hitl_context_summary =
  { summary_version : int
  ; generated_at : float
  ; model_run_id : string
  ; context_summary : string
  ; key_questions : string list
  ; suggested_options : suggested_option list
  ; risk_rationale : string option
  ; uncertainty : float
  }

and summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string; retryable : bool }

type pending_phase =
  | Awaiting_operator
  | Escalated

type lane_policy =
  | Nonblocking
  | Blocking

type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; action_key : string
  ; input_hash : string
  ; sandbox_target : string
  ; sandbox_profile : string option
  ; backend : string option
  ; input : Yojson.Safe.t
  ; risk_level : risk_level
  ; requested_at : float
  ; turn_id : int option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; runtime_contract : Yojson.Safe.t option
  ; selected_model : string option
  ; disposition : string option
  ; disposition_reason : string option
  ; phase : pending_phase
  ; lane_policy : lane_policy
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option
  ; on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option
  ; context_summary : hitl_context_summary option
  ; summary_status : summary_status
  ; channel : Keeper_continuation_channel.t option
  }

type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

type approval_audit_disposition =
  | Approval_escalated of string

type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; sandbox_profile : string option
  ; backend : string option
  ; request_fingerprint : string
  ; request_fingerprint_preview : string
  ; max_risk : risk_level
  ; created_at : float
  ; created_by : string option
  ; last_matched_at : float option
  ; match_count : int
  ; source_approval_id : string option
  }

type rule_match =
  { rule_id : string
  ; matched_by : string
  }

type resolution_result = { remembered_rule : approval_rule option }

val risk_level_to_string : risk_level -> string
val allowed_risk_level_values : string list
val allowed_risk_level_values_label : string
val risk_level_to_int : risk_level -> int
val risk_level_of_string : string -> risk_level option
val pending_phase_to_string : pending_phase -> string
val pending_phase_of_string : string -> pending_phase option
val lane_policy_to_string : lane_policy -> string
val approval_decision_to_string : decision -> string

val approval_audit_decision_to_string : approval_audit_decision -> string
val fingerprint_preview_length : int
(** Length (bytes) of the human-readable fingerprint preview. *)

val string_opt_of_json : Yojson.Safe.t -> string option
val bool_member : string -> Yojson.Safe.t -> default:bool -> bool
val rule_match_to_yojson : rule_match -> Yojson.Safe.t
val approval_rule_to_yojson : approval_rule -> Yojson.Safe.t
val suggested_option_to_yojson : suggested_option -> Yojson.Safe.t
val hitl_context_summary_to_yojson : hitl_context_summary -> Yojson.Safe.t
val summary_status_to_yojson : summary_status -> Yojson.Safe.t

val approval_rule_of_yojson_with_error :
  Yojson.Safe.t -> (approval_rule, string) Stdlib.result
(** Parse an approval rule, returning the first validation failure reason.
    The legacy {!approval_rule_of_yojson} variant silently discards the reason. *)

val approval_rule_of_yojson : Yojson.Safe.t -> approval_rule option
