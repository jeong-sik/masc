(** Receipt-first [Resume_owner] transaction for a paused Keeper lane. *)

type request =
  { owner_generation : int
  ; operator_operation_id : string
  }

type projection_stage =
  | Durable_meta
  | Registry_meta
  | Registry_transition

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Durable_owner_identity_changed
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Registry_owner_missing
  | Registry_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Registry_owner_identity_changed
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Projection_failed of
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

type projection =
  | Applied of Keeper_state_machine.phase
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

val error_to_string : error -> string

val resume :
  Workspace.config ->
  keeper_name:string ->
  request ->
  (success, error) result
(** Persist a typed [Resume_owner] receipt before clearing durable pause state,
    then project the exact registered lane through [Operator_resume] and wake
    it. A post-receipt failure is returned as [Committed_followup_failed], not
    as an uncommitted [Error]. Retry of the same receipt completes any
    interrupted projection. *)
