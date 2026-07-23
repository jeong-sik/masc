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

type exact_attempt_quarantine_cause =
  | Exact_post_dispatch_failure
  | Exact_cancellation
  | Exact_attempt_replay
  | Exact_domain_invalid_output
  | Exact_provenance_mismatch
  | Exact_terminal_persistence_failure
  | Exact_restart_uncertainty

type exact_attempt_status =
  | Exact_dispatch_uncertain
  | Exact_released_before_dispatch
  | Exact_quarantined of exact_attempt_quarantine_cause
  | Exact_completed

type exact_attempt_binding = private
  { approval_id : string
  ; input_hash : string
  ; sequence : int
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_attempt_status
  }

type exact_attempt_state =
  | Exact_unbound
  | Exact_bound of exact_attempt_binding
  | Legacy_execution_uncertain

(** A pending request never owns or suspends a Keeper lane. [sequence] is the
    durable queue-issued order identity; [requested_at] is observation only. *)
type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; input_hash : string
  ; input : Yojson.Safe.t
  ; sequence : int
  ; requested_at : float
  ; turn_id : int option
  ; request_context : Yojson.Safe.t option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; summary_status : summary_status
  ; exact_attempt : exact_attempt_state
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
    the append-only Gate audit log, so reading a rule never rewrites it.
    [expires_at] is an optional absolute Unix expiry: at and after that time
    the rule no longer authorizes. Expiry never deletes the rule; an operator
    removes it through the existing delete path. *)
type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; created_at : float
  ; created_by : string option
  ; source_approval_id : string option
  ; expires_at : float option
  }

type rule_match = { rule_id : string }

(** Exact rule lookup outcome. [Rule_match_expired] keeps the expired rule
    identity observable instead of collapsing it into an absent match. *)
type rule_lookup =
  | Rule_match_active of rule_match
  | Rule_match_expired of rule_match
  | Rule_match_absent

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

val rule_expired : now:float -> approval_rule -> bool
(** [rule_expired ~now rule] is [true] when [rule.expires_at] is set and lies
    at or before [now]. Pure and deterministic; [now] is injected. *)

val rule_store_error_to_string : rule_store_error -> string
val approval_rule_to_yojson : approval_rule -> Yojson.Safe.t
val hitl_context_summary_to_yojson : hitl_context_summary -> Yojson.Safe.t
val summary_status_to_yojson : summary_status -> Yojson.Safe.t
val exact_attempt_status_to_string : exact_attempt_status -> string
val exact_attempt_quarantine_cause_to_string :
  exact_attempt_quarantine_cause -> string
val is_lowercase_sha256 : string -> bool
val exact_attempt_state_to_yojson : exact_attempt_state -> Yojson.Safe.t

val hitl_context_summary_of_yojson_with_error :
  Yojson.Safe.t -> (hitl_context_summary, string) Stdlib.result

val summary_status_of_yojson_with_error :
  Yojson.Safe.t -> (summary_status, string) Stdlib.result

val exact_attempt_state_of_yojson_with_error :
  Yojson.Safe.t -> (exact_attempt_state, string) Stdlib.result

val approval_rule_of_yojson_with_error :
  Yojson.Safe.t -> (approval_rule, string) Stdlib.result
(** Parse an approval rule, returning the first validation failure reason. *)

val approval_rule_of_yojson : Yojson.Safe.t -> approval_rule option
