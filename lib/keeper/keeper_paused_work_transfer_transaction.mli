(** Receipt-first transfer of one exact pending event from a paused Keeper. *)

type request =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; target_generation : int
  ; continuation_binding : Keeper_paused_work_disposition_receipt.continuation_binding
  ; operator_operation_id : string
  ; settled_at : float
  }

type projection_stage =
  | Source_settlement
  | Target_enqueue

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of
      { keeper_name : string
      ; detail : string
      }
  | Durable_meta_missing of string
  | Source_owner_not_paused
  | Source_owner_dead_tombstone
  | Source_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Source_owner_identity_changed
  | Target_owner_not_active
  | Target_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Continuation_binding_mismatch
  | Source_queue_validation_failed of string
  | Committed_projection_failed of
      { stage : projection_stage
      ; detail : string
      }

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type target_projection =
  | Enqueued
  | Already_present

type projection =
  | Applied of
      { source_settlement : Keeper_registry_event_queue.settle_result
      ; target_projection : target_projection
      }
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

val error_to_string : error -> string

val transfer_pending :
  Workspace.config ->
  from_keeper:string ->
  to_keeper:string ->
  request ->
  (success, error) result
(** Persist a typed [Transfer_owner] receipt before terminally settling the
    exact source event, then enqueue that receipt's original stimulus on the
    target lane. Replaying the same receipt completes either interrupted
    projection without duplicating the target event. *)
