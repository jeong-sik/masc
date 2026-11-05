open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types
module Exact_output = Agent_core.Exact_output

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

let create_exact_queue_ops
      ~bind
      ~release_before_dispatch
      ~complete
      ~quarantine
      ~after_bind
  =
  { bind
  ; release_before_dispatch
  ; complete
  ; quarantine
  ; after_bind
  }
;;

let production_exact_queue_ops =
  create_exact_queue_ops
    ~bind:Keeper_approval_queue.bind_summary_exact_attempt
    ~release_before_dispatch:
      Keeper_approval_queue.release_summary_exact_attempt_before_dispatch
    ~complete:Keeper_approval_queue.complete_summary_exact_attempt
    ~quarantine:Keeper_approval_queue.quarantine_summary_exact_attempt
    ~after_bind:(fun () -> ())
;;

let exact_identity_of_candidate
      (candidate : Exact_output.flow_attempt_receipt)
  =
  let receipt = candidate.receipt in
  { slot_id = candidate.visit.identity.candidate_id
  ; call_id =
      receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
  ; plan_fingerprint = Exact_output.receipt_plan_fingerprint receipt
  ; request_body_sha256 =
      Exact_output.receipt_request_body_sha256 receipt
  }
;;

let exact_identity_of_binding (binding : exact_attempt_binding) =
  { slot_id = binding.slot_id
  ; call_id = binding.call_id
  ; plan_fingerprint = binding.plan_fingerprint
  ; request_body_sha256 = binding.request_body_sha256
  }
;;

let with_exact_identity
      (entry : pending_approval)
      (identity : exact_identity)
      transition
  =
  transition
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:identity.slot_id
    ~call_id:identity.call_id
    ~plan_fingerprint:identity.plan_fingerprint
    ~request_body_sha256:identity.request_body_sha256
;;

let bind_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
  =
  with_exact_identity entry identity queue_ops.bind
;;

let release_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
  =
  with_exact_identity entry identity queue_ops.release_before_dispatch
;;

let complete_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      summary
  =
  with_exact_identity
    entry
    identity
    (fun
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
    ->
      queue_ops.complete
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
        ~summary)
;;

type flow_callback_error =
  | Exact_bind_failed of exact_attempt_error
  | Exact_bind_sync_unconfirmed of string
  | Exact_release_failed of exact_attempt_error
  | Exact_release_sync_unconfirmed of string

let flow_callback_error_to_string = function
  | Exact_bind_failed error ->
    "exact bind failed: "
    ^ Keeper_approval_queue_result.exact_attempt_error_to_string error
  | Exact_bind_sync_unconfirmed detail ->
    "exact bind sync unconfirmed: " ^ detail
  | Exact_release_failed error ->
    "exact release failed: "
    ^ Keeper_approval_queue_result.exact_attempt_error_to_string error
  | Exact_release_sync_unconfirmed detail ->
    "exact release sync unconfirmed: " ^ detail
;;

let flow_callback_rejection = function
  | Exact_bind_failed (Exact_attempt_rejected rejection)
  | Exact_release_failed (Exact_attempt_rejected rejection) ->
    Some rejection
  | Exact_bind_failed (Exact_attempt_storage_error _)
  | Exact_release_failed (Exact_attempt_storage_error _)
  | Exact_bind_sync_unconfirmed _
  | Exact_release_sync_unconfirmed _ ->
    None
;;

let before_dispatch ~queue_ops (entry : pending_approval) candidate =
  let identity = exact_identity_of_candidate candidate in
  match bind_exact_attempt queue_ops entry identity with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error (Exact_bind_sync_unconfirmed detail)
  | Error error ->
    Error (Exact_bind_failed error)
;;

let before_advance
      ~queue_ops
      (entry : pending_approval)
      ~failed
      ~next:_
  =
  match failed with
  | Exact_output.Flow_candidate_rejected _ -> Ok ()
  | Exact_output.Flow_candidate_execution_failed { candidate; cause = _ } ->
    let identity = exact_identity_of_candidate candidate in
    (match release_exact_attempt queue_ops entry identity with
     | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
     | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
       Error (Exact_release_sync_unconfirmed detail)
     | Error error ->
       Error (Exact_release_failed error))
;;

let log_exact_error (entry : pending_approval) operation detail =
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output %s failed approval_id=%s: %s"
    operation
    entry.id
    detail
;;

let exact_attempt_source_resolved (entry : pending_approval) = function
  | Exact_attempt_rejected (Exact_attempt_not_found approval_id) ->
    String.equal approval_id entry.id
  | Exact_attempt_storage_error _
  | Exact_attempt_rejected
      ( Exact_attempt_key_mismatch _
      | Exact_attempt_invalid_identity _
      | Exact_attempt_summary_not_pending _
      | Exact_attempt_unbound_state _
      | Exact_attempt_disposition_conflict _
      | Exact_attempt_identity_conflict _
      | Exact_attempt_status_conflict _
      | Exact_attempt_provenance_mismatch _
      | Exact_attempt_content_conflict _ ) -> false
;;
