(** Durable snapshot store for per-keeper Event Layer queues.

    This module lives in [masc.keeper_runtime] so queue persistence stays with
    the queue DTO/codec and does not grow the main keeper surface. *)

val load : base_path:string -> keeper_name:string -> Keeper_event_queue.t
(** Restore a keeper queue snapshot, returning [Keeper_event_queue.empty] when
    no snapshot exists or the snapshot cannot be parsed. *)

val persist :
  base_path:string -> keeper_name:string -> Keeper_event_queue.t -> unit
(** Atomically write the latest queue snapshot. Runtime fibers use a yielding
    Eio mutex; non-Eio setup/test callers use a Stdlib fallback mutex.
    Persistence failures are logged and do not roll back the already-applied
    in-memory registry CAS update. *)

val update :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t -> Keeper_event_queue.t) -> unit
(** Load, transform, and atomically write the queue snapshot while holding the
    persistence write lock. Use this for pre-registry mutation paths that do not
    have a live registry CAS cell yet. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit
(** Evaluate [snapshot] while holding the persistence write lock, then atomically
    write it. Use this after live registry CAS mutations so an older writer
    cannot overwrite a newer live queue snapshot after waiting on the file lock. *)

val record_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Mark drained stimuli as in-flight before they are removed from the pending
    snapshot. [load] merges these rows back in front of pending rows, giving a
    restart at-least-once replay boundary until {!ack_inflight} acknowledges
    them. *)

val ack_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Remove acknowledged stimuli from the in-flight lease after the heartbeat
    turn has completed or after those stimuli have been requeued into the
    pending snapshot. *)

val drain_pending_snapshot :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Remove consumed stimuli from the pending snapshot (event-queue.json). Called
   only on the genuine-ack path ([Keeper_registry_event_queue.ack_consumed]) so
   a stimulus whose turn completed is gone from the next [load]; otherwise a
   race between [record_inflight] and [load]'s prepend re-materializes it and it
   accumulates across restarts. See RFC: keeper-orphan-stimulus-persistence. *)
