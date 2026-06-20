(** Durable snapshot store for per-keeper Event Layer queues.

    This module lives in [masc.keeper_runtime] so queue persistence stays with
    the queue DTO/codec and does not grow the main keeper surface. *)

val load : base_path:string -> keeper_name:string -> Keeper_event_queue.t
(** Restore a keeper queue snapshot, returning [Keeper_event_queue.empty] when
    no snapshot exists or the snapshot cannot be parsed. *)

val persist :
  base_path:string -> keeper_name:string -> Keeper_event_queue.t -> unit
(** Atomically write the latest queue snapshot. Persistence failures are logged
    and do not roll back the already-applied in-memory registry CAS update. *)
