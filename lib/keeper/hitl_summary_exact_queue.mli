(** The durable side of an exact attempt: the identity that names it, the
    queue operations that bind, release and complete it, the callbacks the
    exact-output flow runs before it dispatches or advances, and how a queue
    error says the approval was already resolved. [Hitl_summary_worker]
    includes this module. *)

open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types

type exact_identity =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type exact_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_completion_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> summary:hitl_context_summary
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_quarantine_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> cause:exact_attempt_quarantine_cause
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_queue_ops =
  { bind : exact_transition
  ; release_before_dispatch : exact_transition
  ; complete : exact_completion_transition
  ; quarantine : exact_quarantine_transition
  ; after_bind : unit -> unit
  }

val create_exact_queue_ops :
  bind:exact_transition ->
  release_before_dispatch:exact_transition ->
  complete:exact_completion_transition ->
  quarantine:exact_quarantine_transition ->
  after_bind:(unit -> unit) -> exact_queue_ops

val production_exact_queue_ops : exact_queue_ops

val exact_identity_of_candidate :
  Agent_core.Exact_output.flow_attempt_receipt -> exact_identity

val exact_identity_of_binding :
  exact_attempt_binding -> exact_identity

val with_exact_identity :
  pending_approval ->
  exact_identity ->
  (id:string ->
   input_hash:string ->
   sequence:int ->
   slot_id:string ->
   call_id:string ->
   plan_fingerprint:string -> request_body_sha256:string -> 'a) ->
  'a

val bind_exact_attempt :
  exact_queue_ops ->
  pending_approval ->
  exact_identity ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val release_exact_attempt :
  exact_queue_ops ->
  pending_approval ->
  exact_identity ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

val complete_exact_attempt :
  exact_queue_ops ->
  pending_approval ->
  exact_identity ->
  hitl_context_summary ->
  (exact_attempt_transition,
   exact_attempt_error)
  result

type flow_callback_error =
  | Exact_bind_failed of exact_attempt_error
  | Exact_bind_sync_unconfirmed of string
  | Exact_release_failed of exact_attempt_error
  | Exact_release_sync_unconfirmed of string

val flow_callback_error_to_string : flow_callback_error -> string

val flow_callback_rejection :
  flow_callback_error ->
  exact_attempt_rejection option

val before_dispatch :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  Agent_core.Exact_output.flow_attempt_receipt -> (unit, flow_callback_error) result

val before_advance :
  queue_ops:exact_queue_ops ->
  pending_approval ->
  failed:Agent_core.Exact_output.flow_candidate_failure ->
  next:'a -> (unit, flow_callback_error) result

val log_exact_error :
  pending_approval ->
  string -> string -> unit

val exact_attempt_source_resolved :
  pending_approval ->
  exact_attempt_error -> bool
