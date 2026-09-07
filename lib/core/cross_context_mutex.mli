(** Cooperative mutual exclusion shared by Eio fibers and non-Eio callers. *)

type t

val create : unit -> t

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f] across Eio fibers, system threads, and Domains.

    Eio waiters yield cooperatively instead of blocking their Domain on the
    underlying Stdlib mutex. Cancellation and callback exceptions always
    release both gates before propagating.

    Acquisition is unbounded. An Eio waiter yields until the Stdlib mutex is
    free, with no deadline, no attempt count and nothing written down: a
    holder that never releases leaves the waiter spinning on the scheduler
    while the process stays up and the log stays quiet. The sibling in
    file_lock_eio -- [acquire_flock_retry_cooperative], a lock between
    processes -- bounds itself at 200 attempts, records the outcome and
    raises a named [Flock_timeout]. This one, a lock within the process, does
    none of that. Whether it should is #33588; the bound cannot be borrowed
    from the sibling, because two seconds is right for waiting on a file and
    not for waiting on a fiber. *)

val with_durable_lock : t -> (unit -> 'a) -> 'a
(** Serialize a durable transaction across Eio fibers, system threads, and
    Domains.

    Lock acquisition remains cancellable. Once both gates are acquired, Eio
    cancellation is deferred until [f] finishes and both gates are released.
    Pending parent cancellation is deliberately not checked again at this
    boundary, so a committed persistence operation returns its result before
    cancellation propagates at the caller's next cancellation point. Non-Eio
    callers use the same underlying mutex. *)
