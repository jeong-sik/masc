(** Non-hierarchical HITL queue types and JSON serialization. *)

(** Model judgment attached to an exact Gate request. The queue itself never
    interprets it; Auto Judge may durably resolve [Approve]/[Deny], while
    [Require_human] remains pending for an explicit human resolution. *)
type advisory_judgment =
  | Approve
  | Deny
  | Require_human

type hitl_context_summary =
  { summary_version : int
  ; generated_at : float
  ; model_run_id : string
  ; context_summary : string
  ; key_questions : string list
  ; judgment : advisory_judgment
  ; rationale : string
  }

and summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string; retryable : bool }

(** A pending request never owns or suspends a Keeper lane. *)
type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; input_hash : string
  ; input : Yojson.Safe.t
  ; requested_at : float
  ; turn_id : int option
  ; request_context : Yojson.Safe.t option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; summary_status : summary_status
  }

(** Exact queue resolution. This is an outcome value, not a risk class,
    authorization hierarchy, or provider/tool policy. *)
module Decision : sig
  type t =
    | Approve
    | Reject of string
    | Edit of Yojson.Safe.t
end

type decision = Decision.t

type decision_source =
  | Always_allowed
  | Auto_judge
  | Human_operator

(** An immutable exact Always Allowed rule. Its identity is the workspace-local
    Keeper, opaque operation identity, and complete normalized effect input;
    only JSON object-field order is canonicalized. Match observations belong in
    the append-only Gate audit log, so reading a rule never rewrites it. *)
type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; created_at : float
  ; created_by : string option
  ; source_approval_id : string option
  }

type rule_match = { rule_id : string }

type rule_store_error =
  { path : string
  ; reason : string
  }

type resolution_result = { remembered_rule : approval_rule option }

val advisory_judgment_to_string : advisory_judgment -> string
val advisory_judgment_values : string list
val advisory_judgment_of_string : string -> advisory_judgment option
val approval_decision_to_string : decision -> string
val decision_source_to_string : decision_source -> string
val decision_source_of_string : string -> decision_source option
val string_opt_of_json : Yojson.Safe.t -> string option
val bool_member : string -> Yojson.Safe.t -> default:bool -> bool
val rule_match_to_yojson : rule_match -> Yojson.Safe.t
val rule_store_error_to_string : rule_store_error -> string
val approval_rule_to_yojson : approval_rule -> Yojson.Safe.t
val hitl_context_summary_to_yojson : hitl_context_summary -> Yojson.Safe.t
val summary_status_to_yojson : summary_status -> Yojson.Safe.t

val hitl_context_summary_of_yojson_with_error :
  Yojson.Safe.t -> (hitl_context_summary, string) Stdlib.result

val summary_status_of_yojson_with_error :
  Yojson.Safe.t -> (summary_status, string) Stdlib.result

val approval_rule_of_yojson_with_error :
  Yojson.Safe.t -> (approval_rule, string) Stdlib.result
(** Parse an approval rule, returning the first validation failure reason. *)

val approval_rule_of_yojson : Yojson.Safe.t -> approval_rule option
