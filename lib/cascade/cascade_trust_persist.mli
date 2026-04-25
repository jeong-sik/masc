(** Cascade trust JSONL snapshot.

    Periodically snapshots the global {!Cascade_health_tracker} state to
    [base_path/cascade_trust/YYYY-MM/DD.jsonl] for offline analysis of
    failure fingerprints, success-rate evolution, and provider availability.

    Pull model: a tick fiber polls {!Cascade_health_tracker.all_providers}
    every [snapshot_interval_s] (default 60s, env
    [MASC_CASCADE_TRUST_SNAPSHOT_SEC]) and appends one JSON object per
    tick.  Each object carries [ts] (Unix timestamp) and [providers]
    (list of structured provider rows mirroring {!provider_info}).

    Companion to Phase 0a observability (PR #10292) — fingerprint counter
    in {!Cascade_health_tracker} captures the *what*, this module
    captures the *over time*.  Phase 1 (in-memory trust_score) consumes
    these snapshots offline to calibrate reward / decay defaults.

    Best-effort: I/O failures are logged but never propagated.

    @since 0.174.0 *)

val snapshot_interval_s : float
(** Snapshot tick interval in seconds.  Default 60.0.
    Override via [MASC_CASCADE_TRUST_SNAPSHOT_SEC]. *)

val snapshot_now : base_path:string -> unit
(** Append one snapshot record immediately to today's day-file.  Reads
    {!Cascade_health_tracker.global} via {!Cascade_health_tracker.all_providers}.
    Used by the tick fiber and shutdown hook. *)

val start_snapshot_fiber :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** Spawn a background fiber that calls {!snapshot_now} every
    [snapshot_interval_s].  Registers a shutdown hook for one final
    snapshot. *)

val reset_for_testing : unit -> unit
(** Clear cached store state.  Does not cancel any fiber started via
    {!start_snapshot_fiber}; call only when no fiber is active or after
    its switch has been cancelled. *)
