(** Dashboard response cache — time-bounded memoization with stale-while-revalidate.

    Per-key locking prevents deadlock from nested [get_or_compute] calls while
    still guarding against stampede (multiple fibers computing the same key).
    [compute] functions execute without holding the lock, so nested calls for
    different keys proceed without blocking.

    After a cached value expires, it is still served as stale data for
    [ttl * 3] additional seconds while a background fiber recomputes.
    This prevents slow endpoints from blocking HTTP responses. *)

val set_clock : _ Eio.Time.clock -> unit
(** No-op since #4948 (Time_compat.sleep is the sole sleep path).
    Retained for backward compatibility with existing callers. *)

val set_sw : Eio.Switch.t -> unit
(** Register the server switch for background revalidation fibers.
    Call inside the main [Eio.Switch.run]. *)

val get_or_compute : string -> ttl:float -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** [get_or_compute key ~ttl f] returns a cached value if [key] exists and
    has not expired, otherwise calls [f ()] and stores the result for [ttl]
    seconds.

    If the entry is expired but within the stale grace period ([ttl * 3]),
    the stale value is returned immediately and [f] runs in a background
    fiber (requires [set_sw] to have been called).

    Safe to nest: [f] may call [get_or_compute] for a different key without
    deadlocking.  Concurrent requests for the same key are serialised — only
    one [f] runs; others wait for the result (stampede protection). *)

exception Compute_timeout of string * bool
(** Raised internally when the compute function exceeds [timeout_sec].
    Callers of [get_or_compute_with_timeout] do not need to handle this —
    it is caught and converted to a timeout-error JSON response. *)

val get_or_compute_with_timeout :
  string -> ttl:float -> clock:_ Eio.Time.clock -> timeout_sec:float ->
  (unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** Like [get_or_compute] but wraps the compute function with an Eio timeout.
    On timeout in the stale-while-revalidate path, the stale value is
    preserved (not overwritten by error JSON).  On timeout with no stale
    data, returns a timeout-error JSON without caching it. *)

val invalidate : string -> unit
(** Remove a single cache entry.  If the key is currently being computed,
    waiting fibers are woken and will recompute. *)

val invalidate_prefix : string -> unit
(** Remove all cache entries whose key starts with the given prefix.  If any
    matching entry is currently being computed, waiting fibers are woken and
    will recompute. *)

val invalidate_all : unit -> unit
(** Remove all cache entries. Useful after mutations that change dashboard state. *)

val stats : unit -> Yojson.Safe.t
(** Returns [{"entries": N, "fresh": M, "stale": S, "computing": C, "expired": K}]
    for diagnostics. *)
