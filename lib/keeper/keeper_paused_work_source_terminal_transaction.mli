(** Receipt-first terminal settlement for one exact paused-lane source event. *)

type request =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; source_receipt : Keeper_event_queue_state.source_terminal_receipt
  ; operator_operation_id : string
  ; settled_at : float
  }

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Durable_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Durable_owner_identity_changed
  | Source_queue_validation_failed of string
  | Committed_settlement_failed of string

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type projection =
  | Applied of Keeper_registry_event_queue.settle_result
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

val error_to_string : error -> string

val settle_pending :
  Workspace.config ->
  keeper_name:string ->
  request ->
  (success, error) result
(** Persist [Settle_from_source_terminal] before committing the exact
    source-bearing terminal settlement WAL. Replays never infer terminality
    from time, prose, or an external fallback owner. *)
