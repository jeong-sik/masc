(** Owner-fenced terminal cancellation for one leased accepted event on a paused
    Keeper lane.

    The transaction reserves the Keeper lifecycle generation, verifies both
    durable and live pause ownership, then commits the exact cancellation
    receipt through the event-queue WAL boundary. *)

type request =
  { source_revision : int64
  ; owner_nonce : int
  ; lease : Keeper_registry_event_queue.lease
  ; operator_operation_id : string
  ; reason : string
  ; settled_at : float
  }

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
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Failed of
      { cause : failure
      ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
      }

val failure_to_string : failure -> string
val error_to_string : error -> string

val cancel :
  Workspace.config ->
  keeper_name:string ->
  request ->
  (success, error) result
(** Cancel the exact accepted lease only while its durable and live Keeper
    owner remain explicitly paused at [request.owner_nonce]. The queue
    revision is checked inside the durable owner lock. A committed settlement
    remains a success even if reservation release reports an anomaly; callers
    can inspect [reservation_release] without retrying a committed operation. *)

val cancel_pending :
  Workspace.config ->
  keeper_name:string ->
  pending_request ->
  (success, error) result
(** Cancel the exact pending source under the same paused lifecycle reservation.
    The source-bearing receipt WAL is durable before pending removal is
    checkpointed, and committed replay bypasses current owner fences. *)
