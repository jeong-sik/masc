(** Keeper Subprocess Registry (RFC-0036 Phase A.3).

    Tracks pids of OS subprocesses that the keeper hot path has spawned
    and not yet reaped. Used by the default cleanup hook (see
    [register_default_cleanup_hook]) to SIGTERM-then-SIGKILL any
    subprocess that survives its parent keeper.

    Closes verification report item #32 (Post-stop orphaned process
    handling) for the single-container production topology. The
    multi-container topology of Phase B/C inherits the same registry —
    drain is keyed by [keeper_id], so a [Docker_runtime] subscriber that
    runs `docker rm` on the keeper's container can rely on the same
    subscriber list.

    Concurrency:
    - Registration and unregistration may be called from any fiber.
    - All mutations take a single internal Mutex; pids_for and drain
      snapshot under the lock.
    - drain releases the lock before sending signals to avoid blocking
      register/unregister during a long [waitpid].

    Lifecycle:
    - register/unregister are paired around each spawn site (typically
      via [Fun.protect]).
    - drain consumes the recorded pids and removes them from the
      registry; subsequent [pids_for] returns [[]].
    - Subprocesses that exit cleanly should be unregistered explicitly;
      drain only catches orphans. *)

(** Result of a drain operation. *)
type drain_result = {
  inspected : int;
    (** Total pids drained (sum of sigterm_sent + still_alive). *)
  sigterm_sent : int;
    (** Pids that received SIGTERM and exited within the grace window. *)
  sigkill_sent : int;
    (** Pids that needed SIGKILL after the grace window. *)
  still_alive : int;
    (** Pids that did not respond to either signal (failed kill calls). *)
}

(** Record a pid spawned by [keeper_id]. Idempotent — re-registering
    the same pid is a noop. *)
val register : keeper_id:string -> pid:int -> unit

(** Drop a pid from the registry. Called when a subprocess exits
    cleanly so [drain] does not target an already-reaped pid. *)
val unregister : keeper_id:string -> pid:int -> unit

(** Return the currently-tracked pids for a keeper. Snapshot value;
    safe to iterate even while other fibers register/unregister. *)
val pids_for : keeper_id:string -> int list

(** Sum of currently-tracked pids across all keepers. Useful for
    Otel_metric_store gauge. *)
val total_pids : unit -> int

(** Drain all pids tracked for [keeper_id]:
    1. Send SIGTERM, wait up to [grace_ms].
    2. Send SIGKILL to any still-alive pid.
    3. Remove all targeted pids from the registry.

    [grace_ms] is bounded internally to a sane range (10ms..60s). *)
val drain : keeper_id:string -> grace_ms:int -> drain_result

(** Register the default Tombstone_reaped subscriber against
    [Keeper_lifecycle_hooks]. Idempotent — calling more than once
    only registers one cleanup hook. Called once during supervisor
    bootstrap. *)
val register_default_cleanup_hook : unit -> unit

(** Exact process-local readiness of the mandatory default tombstone cleanup
    hook. Durable completion recovery uses this to avoid acknowledging a
    receipt before the cleanup subscriber is installed. *)
val default_cleanup_hook_registered : unit -> bool

(** Test-only escape hatch: clear the registry. Production code should
    never call this. *)
val reset_for_testing : unit -> unit
