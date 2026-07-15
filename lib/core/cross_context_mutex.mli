(** A mutex shared by Eio fibers and non-Eio system-thread callers.

    Eio fibers first serialize on a cooperative gate, then acquire the shared
    system-thread mutex with [try_lock] and [Fiber.yield].  This prevents a
    second fiber on the same Domain from recursively entering
    [Stdlib.Mutex.lock] while another fiber is suspended inside the critical
    section.  Non-Eio callers acquire the same system-thread mutex directly. *)

type t

val create : unit -> t

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f]. Acquisition and [f] remain cancellable for Eio callers;
    both locks are released before cancellation or an exception propagates. *)

val with_durable_lock : t -> (unit -> 'a) -> 'a
(** Serialize a durable transition. Acquisition remains cancellable, but once
    both locks are held cancellation is deferred until after [f] and lock
    release. The committed result is returned without re-checking the parent
    cancellation context at this boundary. *)
