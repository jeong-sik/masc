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
  -> 'a context
  -> unit
(** Scan all supervised keepers in [Keeper_registry]. Detect zombies
    (resolved Promise), restart without a failure-derived delay, and materialize configured keepalive
    keepers through the required callback. Called periodically by the
    keeper supervisor loop. Failure observations never rewrite [paused]; a
    crashed fiber follows the ordinary per-Keeper restart path. *)

(** {1 Pure Helpers (exposed for testing)} *)

val supervisor_agent_name : string
(** Canonical actor name for supervisor-owned workspace operations. *)

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
