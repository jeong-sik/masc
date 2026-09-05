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

val current_hitl_context_summary_version : int

type summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string }

type exact_attempt_quarantine_cause =
  | Exact_flow_execution_failed
  | Exact_cancellation
  | Exact_attempt_replay
  | Exact_domain_invalid_output
  | Exact_terminal_persistence_failure

type exact_attempt_status =
  | Exact_dispatch_uncertain
  | Exact_released_before_dispatch
  (** Durable no-dispatch proof created by a live flow before restart. *)
  | Exact_released_recovery_required
  (** Install-only nonterminal latch. Only explicit operator recovery may
      return this identity to [Exact_unbound]. *)
  | Exact_quarantined of exact_attempt_quarantine_cause
  | Exact_restart_quarantined
  (** Install-only terminal projection for dispatch-uncertain work. *)
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

val make_exact_attempt_binding :
  approval_id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  unit ->
  exact_attempt_binding

val exact_attempt_binding_with_status :
  exact_attempt_binding -> exact_attempt_status -> exact_attempt_binding

type exact_attempt_state =
  | Exact_unbound
  | Exact_bound of exact_attempt_binding

type summary_attempt_pre_worker_unavailable_code =
  | Summary_pre_worker_auto_judge_unavailable
  | Summary_pre_worker_mode_state_invalid
  | Summary_pre_worker_start_reserved

type summary_attempt_pre_worker_unavailable =
  { reason_code : summary_attempt_pre_worker_unavailable_code
  ; operator_detail : string
  }

type summary_attempt_disposition =
  | Summary_attempt_ready
  | Summary_attempt_in_flight
  | Summary_attempt_identity_unbound
  | Summary_attempt_persistence_uncertain
  | Summary_attempt_pre_worker_unavailable of
      summary_attempt_pre_worker_unavailable
  | Summary_attempt_settled

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
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; summary_status : summary_status
  ; exact_attempt : exact_attempt_state
  ; summary_attempt_disposition : summary_attempt_disposition
  }

(** Exact queue resolution. This is an outcome value, not a risk class,
    authorization hierarchy, or provider/tool policy. *)
module Decision : sig
  type t =
    | Approve
    | Reject of string
end

type decision = Decision.t

type decision_source =
  | Always_allowed
  | Auto_judge
  | Human_operator

(** Which standing authority produced an [Always_allowed] decision.
    [decision_source] answers who decided; this answers under what. The four
    are not interchangeable: [Exact_always_rule] and [One_shot_resolution] are
    an operator acting on one request, while [Keeper_always_allow] and
    [Workspace_always_allow] are blanket permissions that were granted once and
    then applied to everything afterwards. Recording only [Always_allowed]
    leaves an audit reader unable to tell those apart. *)
type authorization_source =
  | One_shot_resolution
  | Exact_always_rule
  | Keeper_always_allow
  | Workspace_always_allow
  | Readonly_sandbox
  | Observed_in_box
      (** The request ran once inside the executor's box and exited 0
          (RFC-0422); the kernel, not a table, said it had no effect. *)

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

val advisory_judgment_to_string : advisory_judgment -> string
val advisory_judgment_values : string list
val advisory_judgment_of_string : string -> advisory_judgment option
val approval_decision_to_string : decision -> string
val decision_source_to_string : decision_source -> string
val decision_source_of_string : string -> decision_source option
val authorization_source_to_string : authorization_source -> string
val authorization_source_of_string : string -> authorization_source option
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
val summary_attempt_pre_worker_unavailable_code_to_string :
  summary_attempt_pre_worker_unavailable_code -> string
val summary_attempt_disposition_to_yojson :
  summary_attempt_disposition -> Yojson.Safe.t

val hitl_context_summary_of_yojson_with_error :
  Yojson.Safe.t -> (hitl_context_summary, string) Stdlib.result

val summary_status_of_yojson_with_error :
  Yojson.Safe.t -> (summary_status, string) Stdlib.result

val exact_attempt_state_of_yojson_with_error :
  Yojson.Safe.t -> (exact_attempt_state, string) Stdlib.result

val summary_attempt_disposition_of_yojson_with_error :
  Yojson.Safe.t -> (summary_attempt_disposition, string) Stdlib.result

val approval_rule_of_yojson_with_error :
  Yojson.Safe.t -> (approval_rule, string) Stdlib.result
(** Parse an approval rule, returning the first validation failure reason. *)

val approval_rule_of_yojson : Yojson.Safe.t -> approval_rule option
