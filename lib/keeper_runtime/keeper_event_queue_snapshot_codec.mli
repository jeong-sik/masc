(** Snapshot encoding that cannot queue behind an owner-lock waiter.

    The shared executor runs recovery jobs that acquire Keeper owner locks.
    Writers already holding those locks must not submit encoding to it.
    This executor accepts only immutable snapshot data, never caller jobs,
    and its workers never acquire an owner lock or submit to another pool. *)

val install : sw:Eio.Switch.t -> _ Eio.Domain_manager.t -> unit
(** Install one independent encoding worker for the server switch lifetime.
    One worker is sufficient to break the shared-pool dependency; no Keeper
    admission or turn limit is imposed. Owner-switch cancellation interrupts
    submissions even when the writer masks its caller's cancellation. Switch
    release clears this installation without clearing a later installation. *)

val encode_state : Keeper_event_queue_state.t -> string
(** Construct, sanitize and pretty-print a snapshot on
    the encoding worker. Exceptions and cancellation propagate without replay.
    Before installation, or from a non-Eio caller, encode in the caller's
    context. Neither path depends on the shared executor. *)
