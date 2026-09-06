(** Cooperative mutual exclusion shared by Eio fibers and non-Eio callers. *)

type t

val create : unit -> t

val lock_cooperatively : Stdlib.Mutex.t -> unit
(** Take a raw [Stdlib.Mutex.t] from an Eio fiber, yielding between attempts
    instead of blocking the Domain on it.

    Exported for the two call sites that own their own [Stdlib.Mutex.t] for the
    same cross-context purpose and cannot pass a {!t}. Three byte-identical
    copies of this loop existed until 2026-09-06; a spin counter added to the
    wrong copy stayed silent through a stall investigation. One copy is one
    place to instrument. *)

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f] across Eio fibers, system threads, and Domains.

    Eio waiters yield cooperatively instead of blocking their Domain on the
    underlying Stdlib mutex. Cancellation and callback exceptions always
    release both gates before propagating. *)

val with_durable_lock : t -> (unit -> 'a) -> 'a
(** Serialize a durable transaction across Eio fibers, system threads, and
    Domains.

    Lock acquisition remains cancellable. Once both gates are acquired, Eio
    cancellation is deferred until [f] finishes and both gates are released.
    Pending parent cancellation is deliberately not checked again at this
    boundary, so a committed persistence operation returns its result before
    cancellation propagates at the caller's next cancellation point. Non-Eio
    callers use the same underlying mutex. *)
