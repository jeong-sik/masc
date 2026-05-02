(** Keeper_supervisor — keeper keepalive fiber supervision.

    Wraps the MASC-owned keeper heartbeat fibers with Promise-based
    liveness tracking via [Keeper_registry]. Detects zombie fibers
    (resolved Promise) and performs automatic restart with exponential
    backoff.

    This does not supervise the OAS [Agent.run] lifecycle.

    @since 2.102.0 *)

open Keeper_types

(** {1 Supervised Execution} *)

val supervise_keepalive :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
(** Start a keeper heartbeat loop inside a supervised fiber.
    Registers in [Keeper_registry] (SSOT) and launches the fiber.
    On fiber termination, resolves the Promise and publishes
    keeper-lifecycle events via Event_bus. *)

(** {1 Watchdog} *)

val fork_stale_watchdog :
  'a context -> keeper_meta -> Keeper_registry.registry_entry -> unit
(** Fork a stale-turn watchdog fiber for the given keeper.

    Two detection modes:
    - Idle stall: [last_turn_ts] older than 300s while [Running].
    - Failure loop: [consecutive_noop_count >= 3] — catches keepers in
      LLM timeout loops where [last_turn_ts] stays fresh.

    On detection, sets [fiber_stop] and emits a stale broadcast. The
    supervisor's [sweep_and_recover] picks up the stopped fiber and
    restarts with exponential backoff. *)

(** {1 Sweep and Recovery} *)

val sweep_and_recover : 'a context -> unit
(** Scan all supervised keepers in [Keeper_registry]. Detect zombies
    (resolved Promise), restart with exponential backoff if within
    budget, mark dead otherwise. Called periodically by the keeper
    supervisor loop. *)

(** {1 Pure Helpers (exposed for testing)} *)

val backoff_delay : int -> float
(** Compute exponential backoff delay for the given attempt number.
    Uses MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S and _MAX_S. *)

val keep_last_n : int -> 'a -> 'a list -> 'a list
(** [keep_last_n n item lst] prepends [item] and keeps at most [n] entries. *)

val next_auto_resume_after_sec :
  initial_sec:float -> max_sec:float -> float option -> float option
(** Compute the next auto-resume backoff delay after an auto-pause.  [None]
    means this is the first auto-pause; [Some sec] means the previous
    backoff should double up to [max_sec].  [initial_sec <= 0] disables
    auto-resume. *)

val should_cleanup_dead : now:float -> dead_ttl_sec:float -> Keeper_registry.registry_entry -> bool
(** True when a dead tombstone has exceeded the configured TTL. *)

val cohort_key_of_reason : Keeper_registry.failure_reason option -> string
(** Map a structured failure_reason to a cohort key for self-preservation grouping. *)

val apply_self_preservation :
  keepers_dir:string ->
  total_keepers:int ->
  (Keeper_registry.registry_entry * string) list ->
  (Keeper_registry.registry_entry * string) list
(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count.
    Returns the filtered list of entries that should proceed with restart. *)
