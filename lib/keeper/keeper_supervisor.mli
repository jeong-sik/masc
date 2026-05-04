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
(** Fork a stale-turn watchdog fiber for the given keeper.  This is a
    re-export of {!Keeper_stale_watchdog.fork_stale_watchdog}; see
    that module's docstring for the authoritative description of the
    three detection modes ([Idle_turn] / [In_turn_hung] /
    [Noop_failure_loop]) and per-class Prometheus counter. *)

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

(** {1 Liveness Recovery} *)

val liveness_recovery_scan : 'a context -> unit
(** Scan all Dead keepers in [Keeper_registry].  For each Dead keeper whose
    root cause is not structural ([credential_archived] or
    [zombie_timeout_reached]) and that has been dead for at least
    [MASC_KEEPER_LIVENESS_RECOVERY_MIN_DEAD_SEC], attempt to re-register and
    relaunch the keepalive fiber.  Uses exponential backoff per keeper and a
    per-keeper attempt budget.  Gated behind
    [MASC_KEEPER_LIVENESS_RECOVERY_ENABLED] (default: true).

    Emits [metric_keeper_liveness_recovery_attempts] and
    [metric_keeper_liveness_recovery_outcomes] Prometheus counters. *)

val liveness_recovery_backoff : int -> float
(** Compute the exponential backoff delay for liveness recovery attempt [n]. *)

val should_attempt_liveness_recovery :
  now:float -> Keeper_registry.registry_entry -> bool
(** Pure predicate: true when a Dead keeper passes the eligibility gate for
    a liveness recovery attempt.  Exposed for tests. *)
