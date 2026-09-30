(** Immutable exact-attempt transitions, applied durably by the queue. *)
open Keeper_approval_queue_rules_types

open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state

type t =
  { changed : bool
  ; updated_entry : pending_approval
  }

let bind ~(candidate : exact_attempt_binding) (entry : pending_approval) =
  match entry.summary_status with
  | Summary_not_requested | Summary_available _ | Summary_failed _ ->
    Error (Exact_attempt_rejected (Exact_attempt_summary_not_pending entry.id))
  | Summary_pending ->
    (match entry.exact_attempt with
     | Exact_unbound
       when not (summary_attempt_allows_exact_bind entry.summary_attempt_disposition) ->
       Error
         (Exact_attempt_rejected
            (Exact_attempt_disposition_conflict
               { approval_id = entry.id; disposition = entry.summary_attempt_disposition }))
     | Exact_unbound ->
       Ok
         { changed = true
         ; updated_entry =
             { entry with
               exact_attempt = Exact_bound candidate
             ; summary_attempt_disposition = Summary_attempt_in_flight
             }
         }
     | Exact_bound _ when entry.summary_attempt_disposition <> Summary_attempt_in_flight
       ->
       Error
         (Exact_attempt_rejected
            (Exact_attempt_disposition_conflict
               { approval_id = entry.id; disposition = entry.summary_attempt_disposition }))
     | Exact_bound existing when exact_attempt_identity_matches existing candidate ->
       (match existing.status with
        | Exact_dispatch_uncertain -> Ok { changed = false; updated_entry = entry }
        | Exact_released_before_dispatch
        | Exact_released_recovery_required
        | Exact_quarantined _
        | Exact_restart_quarantined
        | Exact_completed ->
          Error (Exact_attempt_rejected (Exact_attempt_status_conflict existing)))
     | Exact_bound ({ status = Exact_released_before_dispatch; _ } as _existing) ->
       Ok
         { changed = true
         ; updated_entry =
             { entry with
               exact_attempt = Exact_bound candidate
             ; summary_attempt_disposition = Summary_attempt_in_flight
             }
         }
     | Exact_bound existing ->
       Error (Exact_attempt_rejected (Exact_attempt_identity_conflict existing)))
;;

let release ~(candidate : exact_attempt_binding) (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> Error (Exact_attempt_rejected (Exact_attempt_unbound_state entry.id))
  | Exact_bound existing when not (exact_attempt_identity_matches existing candidate) ->
    Error (Exact_attempt_rejected (Exact_attempt_identity_conflict existing))
  | Exact_bound existing ->
    (match existing.status with
     | Exact_dispatch_uncertain ->
       let released =
         exact_attempt_binding_with_status existing Exact_released_before_dispatch
       in
       Ok
         { changed = true
         ; updated_entry = { entry with exact_attempt = Exact_bound released }
         }
     | Exact_released_before_dispatch -> Ok { changed = false; updated_entry = entry }
     | Exact_quarantined _
     | Exact_released_recovery_required
     | Exact_restart_quarantined
     | Exact_completed ->
       Error (Exact_attempt_rejected (Exact_attempt_status_conflict existing)))
;;

let quarantine ~(candidate : exact_attempt_binding) ~cause (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> Error (Exact_attempt_rejected (Exact_attempt_unbound_state entry.id))
  | Exact_bound existing when not (exact_attempt_identity_matches existing candidate) ->
    Error (Exact_attempt_rejected (Exact_attempt_identity_conflict existing))
  | Exact_bound existing ->
    (match existing.status with
     | Exact_dispatch_uncertain ->
       let quarantined =
         exact_attempt_binding_with_status existing (Exact_quarantined cause)
       in
       Ok
         { changed = true
         ; updated_entry =
             { entry with
               summary_status = exact_attempt_quarantine_summary_status cause
             ; exact_attempt = Exact_bound quarantined
             ; summary_attempt_disposition = Summary_attempt_settled
             }
         }
     | Exact_quarantined durable_cause when durable_cause = cause ->
       let disposition_changed =
         entry.summary_attempt_disposition <> Summary_attempt_settled
       in
       Ok
         { changed = disposition_changed
         ; updated_entry =
             { entry with summary_attempt_disposition = Summary_attempt_settled }
         }
     | Exact_released_before_dispatch
       when cause = Exact_terminal_persistence_failure
            || cause = Exact_cancellation
            || cause = Exact_flow_execution_failed ->
       let quarantined =
         exact_attempt_binding_with_status existing (Exact_quarantined cause)
       in
       Ok
         { changed = true
         ; updated_entry =
             { entry with
               summary_status = exact_attempt_quarantine_summary_status cause
             ; exact_attempt = Exact_bound quarantined
             ; summary_attempt_disposition = Summary_attempt_settled
             }
         }
     | Exact_quarantined _
     | Exact_released_before_dispatch
     | Exact_released_recovery_required
     | Exact_restart_quarantined
     | Exact_completed ->
       Error (Exact_attempt_rejected (Exact_attempt_status_conflict existing)))
;;

let complete ~(candidate : exact_attempt_binding) ~summary (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> Error (Exact_attempt_rejected (Exact_attempt_unbound_state entry.id))
  | Exact_bound existing when not (exact_attempt_identity_matches existing candidate) ->
    Error (Exact_attempt_rejected (Exact_attempt_identity_conflict existing))
  | Exact_bound existing when not (String.equal summary.model_run_id existing.call_id) ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_provenance_mismatch
            { approval_id = entry.id
            ; expected_call_id = existing.call_id
            ; actual_model_run_id = summary.model_run_id
            }))
  | Exact_bound existing ->
    (match existing.status, entry.summary_status with
     | Exact_dispatch_uncertain, Summary_pending ->
       let completed = exact_attempt_binding_with_status existing Exact_completed in
       Ok
         { changed = true
         ; updated_entry =
             { entry with
               summary_status = Summary_available summary
             ; exact_attempt = Exact_bound completed
             ; summary_attempt_disposition = Summary_attempt_settled
             }
         }
     | Exact_completed, Summary_available durable_summary ->
       if
         Yojson.Safe.equal
           (hitl_context_summary_to_yojson durable_summary)
           (hitl_context_summary_to_yojson summary)
       then (
         let disposition_changed =
           entry.summary_attempt_disposition <> Summary_attempt_settled
         in
         Ok
           { changed = disposition_changed
           ; updated_entry =
               { entry with summary_attempt_disposition = Summary_attempt_settled }
           })
       else Error (Exact_attempt_rejected (Exact_attempt_content_conflict entry.id))
     | ( ( Exact_released_before_dispatch
         | Exact_released_recovery_required
         | Exact_quarantined _
         | Exact_restart_quarantined
         | Exact_completed )
       , _ ) -> Error (Exact_attempt_rejected (Exact_attempt_status_conflict existing))
     | Exact_dispatch_uncertain, _ ->
       Error (Exact_attempt_rejected (Exact_attempt_summary_not_pending entry.id)))
;;
