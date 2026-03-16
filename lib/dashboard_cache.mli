(** Dashboard response cache — time-bounded memoization for heavy JSON computations.

    Prevents duplicate computation when multiple dashboard endpoints request
    the same underlying data within a short window (e.g., room-truth + execution). *)

val enable_eio : unit -> unit
(** Activate Eio.Mutex guards. Call once inside [Eio_main.run]. *)

val get_or_compute : string -> ttl:float -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** [get_or_compute key ~ttl f] returns a cached value if [key] exists and
    has not expired, otherwise calls [f ()] and stores the result for [ttl]
    seconds. The mutex is held during [f], which prevents duplicate
    computation for the same key in a cooperative scheduler. *)

val invalidate : string -> unit
(** Remove a single cache entry. *)

val invalidate_all : unit -> unit
(** Remove all cache entries. Useful after mutations that change dashboard state. *)

val stats : unit -> Yojson.Safe.t
(** Returns [{"entries": N, "active": M, "expired": K}] for diagnostics. *)
