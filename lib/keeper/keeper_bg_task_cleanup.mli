(** Keeper Background-Task Cleanup (RFC-0036 Phase A.3.3).

    Bridges [Keeper_lifecycle_hooks.Tombstone_reaped] to
    [Bg_task.list]/[Bg_task.kill] so background bash tasks owned by a
    keeper that just transitioned to Dead are SIGTERM-then-SIGKILL'd
    instead of running until [Bg_task.reap_orphans] sweeps them at the
    next server start.

    Why this lives in lib/keeper/ rather than as a hook inside
    [Bg_task] itself:
    - [Bg_task] is the lower-library generic process facility; it has
      no knowledge of keeper lifecycle.
    - This module is the keeper-specific bridge. It composes existing
      [Bg_task] APIs with [Keeper_lifecycle_hooks] without coupling
      either side to the other.

    Why this exists separately from [Keeper_subprocess_registry]:
    - [Keeper_subprocess_registry] is a generic pid registry for
      future Docker_runtime / call-site tracking (RFC-0036 Phase B/C).
    - [Bg_task] already maintains its own per-keeper task roster with
      PID-file persistence, signal handling, and pgroup tracking. We
      reuse that roster instead of duplicating the bookkeeping.

    Closes verification report item #32 for the
    backgrounded-bash-task case in single-container topology. *)

(** Drain background tasks owned by [keeper_id] using Bg_task's kill
    API:
    1. Enumerate [Bg_task.list ~keeper:keeper_id].
    2. For each task: [Bg_task.kill ~signal:SIGTERM ~grace_sec].
       Bg_task internally escalates to SIGKILL after the grace window.
    3. Return the number of tasks that were targeted (may include some
       already-dying ones — this is best-effort).

    Safe to call from any context. Does not raise. *)
val drain_for_keeper : keeper_id:string -> grace_sec:float -> int

(** Register the Tombstone_reaped subscriber against
    [Keeper_lifecycle_hooks]. Idempotent. Called once during supervisor
    bootstrap, alongside
    [Keeper_subprocess_registry.register_default_cleanup_hook]. *)
val register_default_cleanup_hook : unit -> unit

(** Test-only escape hatch for the idempotency guard. Production code
    should never call this. *)
val reset_for_testing : unit -> unit
