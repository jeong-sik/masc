(** Docker subprocess spawn throttle — bounds host FD pressure.

    Each [docker run/exec/...] call on the macOS host consumes
    host-side pipes/sockets and docker daemon FDs. Without an
    orchestrator-level cap on concurrent spawns, N keepers hitting
    a cascade-exhaustion storm can saturate the system FD ceiling
    (kern.maxfiles, default 491_520).

    Reference incident: 2026-05-16 18:08-18:15 ENFILE storm —
    12+ keepers concurrently retried cascade tiers, each retry
    spawned a fresh [docker run --rm], no backpressure existed at
    the host layer.

    Two layers:

    {ol
    {- Layer A — bounded concurrency via [Eio.Semaphore].
       Effective cap configurable via [MASC_DOCKER_SPAWN_CONCURRENCY]
       (default 8, range 1..64). Always on.}
    {- Layer B — FD-aware serialization. When [Keeper_fd_pressure.active ()]
       indicates the breaker is tripped, an additional global mutex
       funnels all in-flight spawns through a single thread, giving
       the cooldown room to drain. Engaged automatically.}}

    Callers wrap their spawn invocation with [with_slot]; the helper
    blocks until a slot is available. *)

val with_slot : (unit -> 'a) -> 'a
(** [with_slot f] acquires a docker-spawn slot, runs [f ()], releases
    the slot, and returns [f]'s result. If [Keeper_fd_pressure.active ()]
    is true at acquire time, [f] is also serialized against all other
    in-flight callers.

    Exceptions from [f] propagate; the slot is always released. *)

val effective_concurrency : unit -> int
(** [effective_concurrency ()] reports the current cap.
    Returns [1] while [Keeper_fd_pressure.active ()] is true (degraded
    serialization), the configured maximum otherwise. Observability
    only — not a synchronization primitive. *)

val configured_max : unit -> int
(** [configured_max ()] reports the configured upper bound (post-env
    resolution), independent of degraded state. *)
