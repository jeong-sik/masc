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

(** {1 Alive-but-stuck detector (#12838)} *)

val detect_alive_but_stuck :
  now:float ->
  stall_multiplier:int ->
  stall_floor_sec:float ->
  Keeper_registry.registry_entry ->
  float option
(** Pure detection: returns [Some elapsed_sec] when a non-Dead, non-paused
    keeper has gone longer than
    [max(stall_floor_sec, stall_multiplier * proactive.cooldown_sec)]
    without a proactive turn while autonomous turns kept advancing.
    Reference timestamp is [proactive_rt.last_ts] if set, else
    [entry.started_at] (covers the never-started case).  Returns [None]
    otherwise.  Exposed for tests. *)

val alive_but_stuck_scan : 'a context -> unit
(** Scan all keepers in [Keeper_registry].  For each keeper detected as
    alive-but-stuck, emit one [metric_keeper_alive_but_stuck] counter
    increment and a single warn log line, with per-keeper dedup so the
    counter is at most incremented once per
    [alive_but_stuck_dedup_ttl_sec] window.  Also queue a bounded Event
    Layer recovery wakeup for Running keepers, then request supervised
    recovery by setting the keeper's structured failure reason plus
    [fiber_stop]/[fiber_wakeup], allowing the next sweep to route it
    through the existing crash/restart path.  Gated behind
    [MASC_KEEPER_ALIVE_BUT_STUCK_ENABLED] (default: true). *)

val request_alive_but_stuck_recovery_for_test :
  base_path:string ->
  elapsed:float ->
  Keeper_registry.registry_entry ->
  unit
(** Test-only hook for the recovery request side effect used by
    [alive_but_stuck_scan]. *)

val alive_but_stuck_reset_for_test : unit -> unit
(** Test-only: clear the alive-but-stuck dedup table. *)
