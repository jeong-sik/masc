(** Owner-fenced terminal cancellation for one pending accepted event on a paused
    Keeper lane.

    The transaction reserves the Keeper lifecycle generation, verifies both
    durable and live pause ownership, then commits the exact cancellation
    receipt through the event-queue WAL boundary. *)

type pending_request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type failure =
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Queue_replay_failed of string
  | Queue_commit_failed of string

type success =
  { transition : Keeper_registry_event_queue.transition_result
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type error =
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Failed of
      { cause : failure
      ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
      }

val error_to_string : error -> string

val cancel_pending :
  Workspace.config ->
  keeper_name:string ->
  pending_request ->
  (success, error) result
(** Cancel the exact pending source under the same paused lifecycle reservation.
    The source-bearing receipt WAL is durable before pending removal is
    checkpointed, and committed replay bypasses current owner fences. *)
