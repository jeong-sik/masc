(** Building blocks of a Gate decision: the workspace identity every public
    call shares, the one-shot cycle grant, the audit record of an allowed
    request, the pending approval a deferred request enqueues, and the
    refusal an observe run leaves on that row. [Keeper_gate] includes this
    module. *)

open Keeper_gate_types

val canonical_base_path : string -> (string, string) result

val auto_judge_resume_failure_code_to_string :
  auto_judge_resume_failure_code -> string

val completion_rejection_of_exact_attempt :
  Keeper_approval_queue_result.exact_attempt_rejection ->
  auto_judge_completion_rejection

val completion_rejection_operator_detail :
  auto_judge_completion_rejection -> string

val status_label : Unix.process_status -> string

val authorization_source_to_string :
  authorization_source -> string

val unavailable_reason_to_string :
  unavailable_reason -> string

val decision_to_yojson : decision -> Yojson.Safe.t

val authorization_metadata :
  ?producer_metadata:Yojson.Safe.t ->
  authorization -> Yojson.Safe.t

type cycle_grant_entry =
  { approval_id : string }

type cycle_grant_state =
  | Cycle_grant_available of cycle_grant_entry
  | Cycle_grant_consuming of cycle_grant_entry
  | Cycle_grant_consumed

type cycle_grant = cycle_grant_state Atomic.t

type cycle_grant_take_result =
  | Cycle_grant_authorized of string * Keeper_approval.Audit.receipt
  | Cycle_grant_not_applicable
  | Cycle_grant_temporarily_unavailable of string * unavailable_reason

val cycle_grant_of_resolution :
  Keeper_event_queue.hitl_resolution -> cycle_grant option

val take_matching_cycle_grant : cycle_grant -> request -> cycle_grant_take_result

val request_turn_id : request -> int option

val allow :
  request ->
  authorization_source ->
  Keeper_approval.Audit.receipt list -> decision

val observe_authorization_of_failed_result :
  authorization -> unit

val audit_allow :
  request ->
  ?rule_match:Keeper_approval_queue_rules_types.rule_match ->
  ?source_approval_id:string ->
  ?decision_source:Keeper_approval_queue_rules_types.decision_source ->
  authorization_source -> Keeper_approval.Audit.receipt

val submit :
  ?observation:Keeper_approval_queue_rules_types.observed_refusal ->
  request ->
  (Keeper_approval_queue_result.pending_submission,
   Keeper_approval_queue_result.storage_error)
  result

val observed_refusal :
  refusal_kind:Keeper_approval_queue_rules_types.observed_refusal_kind ->
  status:Unix.process_status ->
  stderr:string -> Keeper_approval_queue_rules_types.observed_refusal
