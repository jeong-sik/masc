(** Cooperative mutual exclusion shared by Eio fibers and non-Eio callers. *)

type t

val create : unit -> t

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f] across Eio fibers, system threads, and Domains.

    Eio waiters yield cooperatively instead of blocking their Domain on the
    underlying Stdlib mutex. Cancellation and callback exceptions always
    release both gates before propagating. *)
