(** Dashboard response cache — time-bounded memoization for heavy JSON computations.

    Per-key locking prevents deadlock from nested [get_or_compute] calls while
    still guarding against stampede (multiple fibers computing the same key).
    [compute] functions execute without holding the lock, so nested calls for
    different keys proceed without blocking. *)

val enable_eio : unit -> unit
(** Activate Eio.Mutex guards. Call once inside [Eio_main.run]. *)

val get_or_compute : string -> ttl:float -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** [get_or_compute key ~ttl f] returns a cached value if [key] exists and
    has not expired, otherwise calls [f ()] and stores the result for [ttl]
    seconds.

    Safe to nest: [f] may call [get_or_compute] for a different key without
    deadlocking.  Concurrent requests for the same key are serialised — only
    one [f] runs; others wait for the result (stampede protection). *)

val invalidate : string -> unit
(** Remove a single cache entry.  If the key is currently being computed,
    waiting fibers are woken and will recompute. *)

val invalidate_all : unit -> unit
(** Remove all cache entries. Useful after mutations that change dashboard state. *)

val stats : unit -> Yojson.Safe.t
(** Returns [{"entries": N, "active": M, "computing": C, "expired": K}]
    for diagnostics. *)
