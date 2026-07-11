(** Keeper_supervisor — keeper keepalive fiber supervision.

    Wraps the MASC-owned keeper heartbeat fibers with Promise-based
    liveness tracking via [Keeper_registry]. Detects zombie fibers
    (resolved Promise) and performs automatic restart with exponential
    backoff.

    This does not supervise the OAS [Agent.run] lifecycle.

    @since 2.102.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** {1 Supervised Execution} *)

val supervise_keepalive :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
(** Start a keeper heartbeat loop inside a supervised fiber.
    Registers in [Keeper_registry] (SSOT) and launches the fiber.
    On fiber termination, resolves the Promise and publishes
    keeper-lifecycle events via Event_bus. *)

(** {1 Sweep and Recovery} *)

val pending_hitl_approval_keeper_names : Workspace.config -> string list
(** Return persisted keeper names that currently have a pending HITL
    approval. Used by [sweep_and_recover] to surface otherwise silent
    chat stalls without changing approval/resume behavior. *)

val sweep_and_recover :
     load_or_materialize_keeper_meta:
       ('a context -> string -> (keeper_meta option, string) result)
  -> pacing_enforced:bool
  -> 'a context
  -> unit
(** Scan all supervised keepers in [Keeper_registry]. Detect zombies
    (resolved Promise), restart with exponential backoff if within
    budget, mark dead otherwise, and materialize configured keepalive
    keepers through the required callback. Called periodically by the
    keeper supervisor loop.

    [pacing_enforced] is the RFC-0313 W3 mode, read once per sweep by the
    caller (production wires [Keeper_pacing_shadow.pacing_enforced ()]).
    When [true] (default runtime config), [Pause_keeper] policy verdicts
    route to the standard restart/backoff path; when [false] (shadow
    kill-switch, removed in W4), the legacy failure-driven pause arms run. *)

(** {1 Pure Helpers (exposed for testing)} *)

val supervisor_agent_name : string
(** Canonical actor name for supervisor-owned workspace operations. *)

val backoff_delay : int -> float
(** Compute exponential backoff delay for the given attempt number.
    Uses MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S and _MAX_S. *)

val keep_last_n : int -> 'a -> 'a list -> 'a list
(** [keep_last_n n item lst] prepends [item] and keeps at most [n] entries. *)

type done_signal_resolution =
  | Done_signal_resolved_now
  | Done_signal_already_resolved
  | Done_signal_already_seen
(** Supervisor-local classification for attempts to resolve a keeper done
    promise. [Done_signal_already_resolved] still suppresses finally cleanup,
    but it must not publish a lifecycle event for an already-owned outcome. *)

val done_signal_of_registry_result :
  Keeper_registry.done_resolve_result -> done_signal_resolution
(** Collapse the registry result into supervisor-local lifecycle ownership. *)

val should_publish_lifecycle_for_done_signal : done_signal_resolution -> bool
(** True only when this supervisor branch resolved [done_p] itself. *)

val persona_name_for_drift_check :
  keeper_meta -> (string, Keeper_types_profile.keeper_toml_load_error) result
(** Resolve the persona handle used by supervisor persona-drift checks.
    Honors keeper TOML [persona_name] overlays and preserves typed config
    failures instead of projecting a fallback identity. *)

val persona_profile_path_for_drift_check :
  base_path:string -> string -> string
(** Return the concrete persona [profile.json] path reported by supervisor
    drift diagnostics. *)

(** supervision_cohort type + cohort/persona helpers live in
    Keeper_supervisor_types (intra-library file split, 2026-05-16).
    Re-exported here so existing callers keep using
    [Keeper_supervisor.supervision_cohort] etc. unchanged. *)
include module type of Keeper_supervisor_types


val cohort_key_of_reason : Keeper_registry.failure_reason option -> string
(** Map a structured failure_reason to a cohort key for self-preservation grouping. *)

val assess_stale_run :
     phase:Keeper_state_machine.phase
  -> in_turn:'a option
  -> last_turn_ts:float
  -> started_at:float
  -> now:float
  -> threshold:float
  -> Keeper_registry.failure_reason option
(** RFC-0250: pure stale-run assessment for the no-turn-produced case. Returns
    [Some (Stale_turn_timeout (Idle_turn { stall_seconds }))] — the
    [Idle_turn] variant's first real producer — when [phase = Running], the
    keeper is not in a turn ([in_turn = None]), has completed at least one
    turn ([last_turn_ts > 0]), and [now] exceeds both [last_turn_ts] and the
    current supervised lifetime [started_at] by more than [threshold]. The
    lifetime gate prevents a restart from immediately inheriting stale metadata
    and exhausting restart budget before one idle window elapses. [None]
    otherwise. Exposed for regression tests. *)

val assess_in_turn_progress :
     phase:Keeper_state_machine.phase
  -> in_turn:Keeper_registry_types.turn_observation option
  -> now:float
  -> progress_timeout:float
  -> Keeper_registry.failure_reason option
(** RFC-0012: pure in-turn progress-silence assessment. Returns
    [Some (Stale_turn_timeout (Mid_turn_no_progress { ... }))] — the
    [Mid_turn_no_progress] variant's first real producer — when [phase = Running]
    with a turn in progress ([in_turn = Some obs]) whose [last_progress_at] is
    older than [progress_timeout]. [None] otherwise (not running, no turn in
    progress, or progress recorded within the window). Keys on recorded progress
    events, distinct from the no-turn [Idle_turn] case (not raw turn wall-clock).
    Exposed for regression tests. *)

val failure_reason_policy_decision_for_test :
  Keeper_registry.failure_reason option -> Keeper_failure_policy.decision option
(** Pure supervisor-side bridge from registry failure reasons into the
    keeper failure policy matrix. Exposed for regression tests so pause-vs-restart
    lifecycle ownership remains pinned to [Keeper_failure_policy]. *)

val apply_self_preservation :
  keepers_dir:string ->
  total_keepers:int ->
  (Keeper_registry.registry_entry * string) list ->
  (Keeper_registry.registry_entry * string) list
(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count.
    Bounded minority [stale_turn_timeout] cohorts are allowed through while
    larger stale cohorts still use the circuit breaker/probe path.
    Returns the filtered list of entries that should proceed with restart. *)

val reset_self_preservation_escape_state_for_test : unit -> unit
(** Reset the self-preservation probe state. Test-only. *)

val active_supervision_keeper_count :
  Keeper_registry.registry_entry list -> int
(** Count currently active keepers for self-preservation denominators. *)

val set_restart_launch_noop_for_test : bool -> unit
(** Test-only: when enabled, restart bookkeeping still runs but the
    replacement heartbeat/watchdog fibers are not forked. *)

val restart_launch_noop_enabled_for_test : unit -> bool
(** Test-only: inspect the restart-launch noop flag. *)

val with_restart_launch_noop_for_test : (unit -> 'a) -> 'a
(** Test-only: scoped restart-launch noop override. Nested and overlapping
    scopes restore the prior flag only after the outer scope exits. *)

val set_global_switch : Eio.Switch.t -> unit
(** Set the global server switch to run keepalive fibers and supervisor sweeps
    under a long-lived context. *)

val get_global_switch : unit -> Eio.Switch.t option
(** Retrieve the global server switch if configured. *)
