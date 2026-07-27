(** Owner-fenced terminal cancellation for one leased accepted event on a paused
    Keeper lane.

    The transaction reserves the Keeper lifecycle generation, verifies both
    durable and live pause ownership, then commits the exact cancellation
    receipt through the event-queue WAL boundary. *)

(* [request] carried a [Keeper_registry_event_queue.lease] and drove [cancel],
   the active-lease arm of this transaction. #25969 moved production to
   peek/ack, after which no caller could obtain a lease and
   [Keeper_event_queue_state.of_yojson] restored none, so that arm could not
   run. The pending arm below needs no lease. *)
type pending_request =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  ; settled_at : float
  }

type failure =
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Durable_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Registry_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Lease_source_invalid
  | Queue_replay_failed of string
  | Queue_commit_failed of string

type success =
  { settlement : Keeper_registry_event_queue.settle_result
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type error =
  | Admission_busy of Keeper_turn_admission.autonomous_block
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Failed of
      { cause : failure
      ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
      }

val failure_to_string : failure -> string
val error_to_string : error -> string

val cancel_pending :
  Workspace.config ->
  keeper_name:string ->
  pending_request ->
  (success, error) result
(** Cancel the exact pending source under the same paused lifecycle reservation.
    The source-bearing receipt WAL is durable before pending removal is
    checkpointed, and committed replay bypasses current owner fences. *)
