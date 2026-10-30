(** Operator snapshot cache — stale-while-revalidate with background refresh.

    The dashboard calls [Operator_control_snapshot.snapshot_json] frequently,
    but the snapshot can take tens of seconds to build.  This cache serves the
    previous snapshot immediately while a background fiber recomputes, so the
    dashboard never waits on the hot path. *)

val get_or_compute : string -> ttl:float -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** [get_or_compute key ~ttl compute] returns a cached snapshot for [key] when
    one exists and has not expired. Otherwise it calls [compute] and stores the
    result for [ttl] seconds.

    If the entry is expired but still within the stale grace window
    ([ttl * cache_stale_grace_factor]), the stale snapshot is returned
    immediately and [compute] runs in a background fiber (requires the process
    switch to have been registered via [Eio_context.set_switch]).

    Concurrent requests for the same key are serialised: only one [compute]
    runs at a time, and waiters poll with a bounded, cancellation-safe loop. *)

val peek : string -> Yojson.Safe.t option
(** [peek key] returns the currently cached snapshot for [key] when a fresh or
    stale-ready entry exists. Unlike [get_or_compute], it never triggers a
    synchronous compute. Returns [None] on cache miss or when the key is
    currently computing without any stale fallback. *)

val invalidate_snapshot_cache : unit -> unit
(** Drops every cached operator snapshot entry. Called automatically by
    keeper-mutation routes so the next snapshot read sees fresh state. *)

val stats : unit -> Yojson.Safe.t
(** Returns [{"entries": N, "fresh": M, "stale": S, "expired": E,
    "computing": C, "max_entries": K}] for diagnostics. *)
