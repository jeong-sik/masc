(** Fleet health telemetry — incremental, non-blocking summary of keeper
    registry state for proactive anomaly detection (task-702 Fix Plan B).

    Pure projection from [Keeper_registry.registry_entry list]; no sweep
    loop, no fiber, no mutable state.  Caller (dispatcher, supervisor, or
    an on-demand dashboard) invokes [summarize] on the current snapshot and
    reads the result synchronously. *)

open Keeper_registry_types

(** Raw fleet counts broken down by lifecycle phase. *)
type phase_counts =
  { online : int       (** [Running] keepers *)
  ; observe : int      (** [Failing] keepers under observation *)
  ; offline : int      (** [Offline] keepers *)
  ; paused : int       (** [Paused] keepers *)
  ; overflowed : int   (** [Overflowed] keepers *)
  ; compacting : int   (** [Compacting] keepers *)
  ; handing_off : int  (** [HandingOff] keepers *)
  ; draining : int     (** [Draining] keepers *)
  ; stopped : int      (** [Stopped] keepers *)
  ; crashed : int      (** [Crashed] keepers *)
  ; restarting : int   (** [Restarting] keepers *)
  ; zombie : int       (** [Zombie] keepers *)
  ; dead : int         (** [Dead] keepers *)
  ; total : int        (** total tracked entries *)
  }

(** Per-keeper health indicator. *)
type keeper_health =
  { name : string
  ; phase : Keeper_state_machine.phase
  ; alive : bool
  ; restart_count : int
  ; last_restart_ago_sec : float option
  ; consecutive_failures : int
  ; dead_since_ago_sec : float option
  ; last_error : string option
  ; last_failure_reason : failure_reason option
  }

(** Aggregate anomaly signals. *)
type anomaly_flags =
  { empty_fleet : bool
      (** No keepers registered at all. *)
  ; all_dead : bool
      (** Every tracked keeper is dead/failed. *)
  ; cascade_restart : bool
      (** >=3 keepers restarted within cascade_window_sec. *)
  ; multiple_paused : bool
      (** >=2 keepers stuck in [Paused]. *)
  ; failure_spike : bool
      (** >=1 keeper with >=failure_spike_threshold consecutive failures. *)
  }

(** Complete telemetry summary for one observation point. *)
type telemetry_snapshot =
  { sampled_at : float
  ; counts : phase_counts
  ; keepers : keeper_health list
  ; anomalies : anomaly_flags
  ; dead_keepers : keeper_health list
  ; paused_keepers : keeper_health list
  }

(** Compute an incremental telemetry snapshot from a registry snapshot.
    Pure — no side effects, no I/O, no fiber. *)
val summarize :
  now:float ->
  stale_dead_threshold_sec:float ->
  cascade_window_sec:float ->
  failure_spike_threshold:int ->
  registry_entry list ->
  telemetry_snapshot
