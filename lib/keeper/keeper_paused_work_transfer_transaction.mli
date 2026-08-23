(** Receipt-first transfer of one exact pending event from a paused Keeper. *)

type request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; continuation_binding : Keeper_paused_work_disposition_receipt.continuation_binding
  ; operator_operation_id : string
  }

type projection_stage =
  | Source_ack
  | Target_enqueue

type failure =
  | Invalid_request of string
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
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
  | Source_owner_identity_changed
  | Target_owner_not_active
  | Target_owner_identity_changed
  | Continuation_binding_mismatch
  | Source_queue_validation_failed of string
  | Source_transfer_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Target_transfer_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
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
  | Applied of target_projection
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

val error_to_string : error -> string

val project_committed_target_if_receipted :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token ->
  Workspace.config ->
  transfer:Keeper_registry_event_queue.accepted_transfer ->
  (target_projection option, failure) result
(** If [transfer] originated from a durable paused-work receipt, validate that
    receipt's exact target generation and trace before projecting it. [None]
    means no paused-work receipt owns this generic operator transfer. Receipt
    conflicts and target identity changes fail closed. *)

val transfer_pending :
  Workspace.config ->
  from_keeper:string ->
  to_keeper:string ->
  request ->
  (success, error) result
(** Persist a typed [Transfer_owner] receipt before ACKing the exact source
    event, then enqueue that receipt's original stimulus on the
    target lane. Replaying the same receipt completes either interrupted
    projection without duplicating the target event. New transactions hold
    the source lifecycle reservation before both source and target
    durable-intake fences; the two intake fences are acquired in deterministic
    Keeper-name order across receipt and queue mutation. *)
