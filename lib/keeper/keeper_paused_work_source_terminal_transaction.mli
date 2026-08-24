(** Receipt-first source ACK for one exact paused-lane terminal event. *)

type request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; source_receipt : Keeper_event_queue_state.source_terminal_receipt
  ; operator_operation_id : string
  }

type failure =
  | Invalid_request of string
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_identity_changed
  | Source_queue_validation_failed of string
  | Committed_ack_failed of string

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type projection =
  | Applied of Keeper_registry_event_queue.source_ack_result
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

val error_to_string : error -> string

val ack_pending :
  Workspace.config ->
  keeper_name:string ->
  request ->
  (success, error) result
(** Persist [Ack_source_terminal] before committing the exact source-terminal
    ACK. Replays never infer terminality
    from time, prose, or an external fallback owner. *)
