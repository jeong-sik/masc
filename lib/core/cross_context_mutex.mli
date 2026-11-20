(** Cooperative mutual exclusion shared by Eio fibers and non-Eio callers.

    State transitions are guarded by a short internal [Stdlib.Mutex.t] that is
    never held across callbacks, Eio yields, or blocking operations. Eio fibers
    suspend cooperatively on an [Eio.Condition.t] with no polling loop, while
    non-Eio callers (systhreads and external Domains) wait on a paired
    [Stdlib.Condition.t]. *)

type t

val create : unit -> t

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f] across Eio fibers, system threads, and Domains.

    Eio waiters suspend cooperatively on an internal [Eio.Condition.t] instead
    of blocking their Domain or polling. No [Stdlib.Mutex.t] is held while [f]
    runs, so [f] may perform arbitrary Eio operations and yields. Cancellation
    and callback exceptions always release the lock before propagating. *)

val try_with_lock : t -> (unit -> 'a) -> 'a option
(** Run [f] only when the lock is free now; [None] when another holder holds
    it, without waiting. Cancellation and callback exceptions release the lock
    before propagating. *)

val with_durable_lock : t -> (unit -> 'a) -> 'a
(** Serialize a durable transaction across Eio fibers, system threads, and
    Domains.

    Lock acquisition remains cancellable. Once acquired, Eio cancellation is
    deferred until [f] finishes and the lock is released. Pending parent
    cancellation is deliberately not checked again at this boundary, so a
    committed persistence operation returns its result before cancellation
    propagates at the caller's next cancellation point. Non-Eio callers wait on
    the paired OS condition variable using the same underlying state. *)
