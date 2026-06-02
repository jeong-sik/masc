(** Subsystem_health — process-wide registry of forked subsystems
    and their alive/dead state.

    Module-level [Hashtbl] guarded by [Stdlib.Mutex] (cross-domain:
    /health handler may run on a different domain than the fork
    callers, ruling out [Eio.Mutex]). Available from process start
    with no init timing dependency.

    Internal helpers (the [registry] table, [registry_mu] mutex,
    and [with_lock] critical-section wrapper) are hidden — callers
    consume only the three lifecycle entry points below. *)

val register : string -> unit
(** Mark [name] as alive in the registry. Called from
    [fork_subsystem] in [server_bootstrap_loops] when a subsystem
    fiber is forked. Idempotent — re-registers as alive with no
    crash time even if the entry already exists. *)

val mark_dead : string -> unit
(** Mark [name] as dead and stamp its crash time
    ([Time_compat.now ()]). Called from the supervisor fiber
    when it observes a crash. Idempotent — overwrites any prior
    entry with the new crash timestamp. *)

val to_yojson : unit -> Yojson.Safe.t
(** Render the registry as a JSON object keyed by subsystem name,
    sorted alphabetically. Each value is
    [\{ "status": "alive" | "dead", "crashed_at"?: float \}].
    Consumed by the HTTP [/health] handler in
    [server_routes_http_runtime]. *)
