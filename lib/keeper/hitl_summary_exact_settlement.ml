open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types
open Hitl_summary_flow_outcome
open Hitl_summary_exact_queue

exception Exact_terminalization_persistence_failed of string
exception Exact_terminalization_rejected of exact_attempt_rejection
exception Cancelled_uncertain of exn * Printexc.raw_backtrace * string
exception Exact_terminalization_identity_unbound of string
exception Cancelled_identity_unbound of exn * Printexc.raw_backtrace
exception Cancelled_exact_rejected of
  exn * Printexc.raw_backtrace * exact_attempt_rejection

type exact_settlement_error =
  | Exact_settlement_identity_unbound of string
  | Exact_settlement_persistence_failed of string
  | Exact_settlement_rejected of exact_attempt_rejection

type cancellation_settlement =
  | Cancellation_settled
  | Cancellation_exact_settlement_failed of exact_settlement_error
  | Cancellation_settlement_raised of string

let mark_identity_unbound (entry : pending_approval) =
  Keeper_approval_queue.mark_summary_attempt_identity_unbound
    ~base_path:entry.audit_base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
;;

let mark_persistence_uncertain (entry : pending_approval) =
  Keeper_approval_queue.mark_summary_attempt_persistence_uncertain
    ~base_path:entry.audit_base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
;;

let persist_identity_unbound (entry : pending_approval) =
  match mark_identity_unbound entry with
  | Ok true -> Ok ()
  | Ok false ->
    Error `Transition_not_applied
  | Error (Exact_attempt_storage_error error) ->
    Error (`Storage_failed (Keeper_approval_queue_result.storage_error_to_string error))
  | Error (Exact_attempt_rejected rejection) ->
    Error (`Rejected rejection)
;;

let signal_terminalization_persistence_failure
      (entry : pending_approval)
      operation
      detail
  =
  (match mark_persistence_uncertain entry with
   | Ok _ -> ()
   | Error marker_error ->
     log_exact_error
       entry
       "persistence uncertainty observation"
       (Keeper_approval_queue_result.exact_attempt_error_to_string marker_error));
  record_outcome Terminal_persistence_failure;
  log_exact_error entry operation detail;
  raise
    (Exact_terminalization_persistence_failed
       (Printf.sprintf
          "HITL exact-output %s failed approval_id=%s: %s"
          operation
          entry.id
          detail))
;;

type exact_queue_terminalization_error =
  | Exact_queue_persistence_failed of string
  | Exact_queue_rejected of exact_attempt_rejection

let quarantine_identity_result
      ~queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match
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
        queue_ops.quarantine
          ~id
          ~input_hash
          ~sequence
          ~slot_id
        ~call_id
        ~plan_fingerprint
          ~request_body_sha256
          ~cause)
  with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error
      (Exact_queue_persistence_failed
         ("quarantine durability confirmation failed: " ^ detail))
  | Error error when exact_attempt_source_resolved entry error ->
    record_outcome Source_resolved;
    Ok ()
  | Error (Exact_attempt_storage_error error) ->
    Error
      (Exact_queue_persistence_failed
         (Keeper_approval_queue_result.storage_error_to_string error))
  | Error (Exact_attempt_rejected rejection) ->
    Error (Exact_queue_rejected rejection)
;;

let quarantine_identity
      ~queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match quarantine_identity_result ~queue_ops entry identity cause with
  | Ok () -> ()
  | Error (Exact_queue_persistence_failed detail) ->
    signal_terminalization_persistence_failure
      entry
      "quarantine persistence"
      detail
  | Error (Exact_queue_rejected rejection) ->
    raise (Exact_terminalization_rejected rejection)
;;

let quarantine_candidate ~queue_ops (entry : pending_approval) candidate cause =
  quarantine_identity
    ~queue_ops
    entry
    (exact_identity_of_candidate candidate)
    cause
;;

let settle_current ~queue_ops (entry : pending_approval) ~reason ~cause =
  match
    Keeper_approval_queue.get_pending_entry_for_workspace
      ~base_path:entry.audit_base_path
      ~id:entry.id
  with
  | Error error ->
    Error
      (Exact_settlement_persistence_failed
         (Keeper_approval_queue_result.storage_error_to_string error))
  | Ok None ->
    record_outcome Source_resolved;
    Ok ()
  | Ok (Some { exact_attempt = Exact_unbound; _ }) ->
    Error
      (Exact_settlement_identity_unbound
         (Printf.sprintf
            "HITL exact-output terminalization requires a bound attempt identity approval_id=%s: %s"
            entry.id
            reason))
  | Ok
      (Some
      { exact_attempt =
          Exact_bound { status = (Exact_completed | Exact_quarantined _); _ }
      ; _
      }) ->
    record_outcome Source_resolved;
    Ok ()
  | Ok
      (Some
        { exact_attempt =
            Exact_bound
              ({ status =
                   ( Exact_dispatch_uncertain
                   | Exact_released_before_dispatch
                   | Exact_released_recovery_required
                   | Exact_restart_quarantined )
               ; _
               } as binding)
        ; _
        }) ->
    quarantine_identity_result
      ~queue_ops
      entry
      (exact_identity_of_binding binding)
      cause
    |> Result.map_error (function
      | Exact_queue_persistence_failed detail ->
        Exact_settlement_persistence_failed detail
      | Exact_queue_rejected rejection ->
        Exact_settlement_rejected rejection)
;;

let signal_settlement_error (entry : pending_approval) = function
  | Exact_settlement_identity_unbound detail ->
    (match persist_identity_unbound entry with
     | Ok () ->
       record_outcome Identity_unbound;
       log_exact_error entry "terminalization blocked" detail;
       raise (Exact_terminalization_identity_unbound detail)
     | Error `Transition_not_applied ->
       record_outcome Identity_unbound_source_changed;
       raise (Exact_terminalization_identity_unbound detail)
     | Error (`Rejected rejection) ->
       raise (Exact_terminalization_rejected rejection)
     | Error (`Storage_failed marker_detail) ->
       signal_terminalization_persistence_failure
         entry
         "identity-unbound observation"
         marker_detail)
  | Exact_settlement_persistence_failed detail ->
    signal_terminalization_persistence_failure
      entry
      "terminalization persistence"
      detail
  | Exact_settlement_rejected rejection ->
    raise (Exact_terminalization_rejected rejection)
;;

let settle_current_or_signal ~queue_ops (entry : pending_approval) ~reason ~cause =
  match settle_current ~queue_ops entry ~reason ~cause with
  | Ok () -> ()
  | Error error -> signal_settlement_error entry error
;;
