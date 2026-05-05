(** Coord_resilience — single source of truth for failure handling.

    Three sub-modules organise the resilience helpers:

    - {!Time}: monotonic-clock + ISO 8601 parsing.
    - {!Zombie}: agent-staleness detection with per-class thresholds
      (regular vs keeper agents).
    - {!ZeroZombie}: cleanup-loop bookkeeping for the zero-zombie
      protocol that runs in the background.

    Renamed from [Resilience] (cycle 100 / fix #11709) so the module
    name does not shadow the [masc_mcp.resilience] sub-library that
    PR #11695 started using via [Resilience.Keeper_bridge].

    @since Single source of truth — failure handling consolidation *)

val default_zombie_threshold : float
(** Reads [Env_config_runtime.Zombie.threshold_seconds].
    Default: 300.0 (5 minutes).  Operator override:
    [MASC_ZOMBIE_THRESHOLD_SEC]. *)

val default_warning_threshold : float
(** [120.0] (2 minutes).  Pinned at the contract seam — a future
    "let's tune the inactivity warning" change must touch this
    constant explicitly so dashboard "agent inactive" copy stays in
    sync. *)

(** {1 Time helpers} *)

module Time : sig
  val now : unit -> float
  (** [now ()] returns the current monotonic Unix-epoch seconds via
      {!Time_compat.now}. *)

  val parse_iso8601_opt : string -> float option
  (** [parse_iso8601_opt s] parses an ISO 8601 UTC timestamp.
      Delegates to {!Types_core.parse_iso8601_opt}.  On parse
      failure logs at {!Log.Misc.error} and returns [None] —
      operator runbooks grep on "parse_iso8601_opt failed for:"
      to detect malformed [last_seen] timestamps in agent state. *)

  val is_stale : ?threshold:float -> string -> bool
  (** [is_stale ?threshold timestamp_str] returns [true] iff
      [now () - parse(timestamp_str)] exceeds [threshold]
      (default {!default_zombie_threshold}).

      {b Important}: malformed timestamps return [true] (treated
      as stale/zombie).  This is fail-loud — silent acceptance of
      bad timestamps would let agents avoid eviction by writing
      garbage.  A future "tolerate parse errors" change would
      reopen the eviction-bypass class. *)
end

(** {1 Zombie detection} *)

module Zombie : sig
  val is_keeper_name : string -> bool
  (** [is_keeper_name name] tests whether [name] matches the
      keeper convention [keeper-*-agent] (case-insensitive,
      trimmed).  Used to apply the longer keeper threshold. *)

  val is_zombie : ?threshold:float -> string -> bool
  (** [is_zombie ?threshold last_seen_iso] is a thin alias for
      {!Time.is_stale}. *)

  val is_keeper :
    name:string -> agent_type:string -> bool
  (** [is_keeper ~name ~agent_type] returns [true] when EITHER:
      - [name] matches the keeper-name convention, OR
      - [agent_type] equals ["keeper"] (case-insensitive, trimmed)

      Name-only matching is insufficient because non-pattern keeper
      agents still need the keeper threshold, while legacy
      [keeper-*-agent] names keep the same behavior. *)

  val is_zombie_for_agent :
    ?keeper_threshold_sec:float ->
    ?agent_threshold_sec:float ->
    ?agent_type:string ->
    agent_name:string ->
    string ->
    bool
  (** [is_zombie_for_agent ?keeper_threshold_sec ?agent_threshold_sec
      ?agent_type ~agent_name last_seen_iso] uses
      {!Env_config_runtime.Zombie.keeper_threshold_seconds} when
      {!is_keeper} matches the name or type, otherwise falls back to
      {!default_zombie_threshold}.  Callers may override both
      thresholds for deterministic tests or one-off cleanup windows.
      This is the canonical "should I evict this agent" predicate for
      the gc loop. *)
end

(** {1 Zero-Zombie protocol}

    Background cleanup loop that runs periodically, invoking a
    caller-supplied [cleanup_fn] and recording stats.  Used by the
    bootstrap code to ensure stale agents do not accumulate. *)

module ZeroZombie : sig
  type stats = {
    mutable total_cleanups : int;
    mutable last_cleanup_ts : float;
    mutable last_cleaned_agents : string list;
  }
  (** Concrete record because the global [global_stats] is exposed
      and dashboards mutate it in place.  All fields are mutable
      to avoid allocation in the cleanup hot path. *)

  val global_stats : stats
  (** Singleton stats record updated by every {!cleanup} call.
      Operators inspect this through the dashboard's
      "zero-zombie protocol" surface card. *)

  val cleanup : cleanup_fn:(unit -> string list) -> string list
  (** [cleanup ~cleanup_fn] runs [cleanup_fn ()].  When the result
      is non-empty:
      - increments [global_stats.total_cleanups],
      - sets [last_cleanup_ts] to current time,
      - replaces [last_cleaned_agents] with the result.

      Returns the cleaned-agents list verbatim. *)

  val is_benign_error : exn -> bool
  (** [is_benign_error exn] returns [true] for two transient
      patterns operators expect at startup:
      - [Invalid_argument("MASC...")] — MASC not initialized yet.
      - [Sys_error("No such file...")] — transient race during
        directory creation.

      The two prefixes are pinned at 20 / 14 chars respectively;
      the prefix-match approach is intentional so a future
      exception-message tweak does not reopen the noisy-warning
      surface. *)

  val run_loop :
    ?interval:float ->
    clock:_ Eio.Time.clock ->
    cleanup_fn:(unit -> string list) ->
    unit ->
    unit
  (** [run_loop ?interval ~clock ~cleanup_fn ()] is the long-lived
      background fiber: sleep [interval] seconds (default
      [60.0]), call {!cleanup}, repeat.

      {2 Cancellation}

      [Eio.Cancel.Cancelled] is re-raised from every nesting
      level so a switch teardown propagates immediately.

      {2 Error policy}

      Sleep failures are logged at {!Log.Misc.error} but the loop
      continues.  Cleanup failures are split:
      - {!is_benign_error} → silently ignored (no log noise)
      - other → {!Log.Misc.error} but the loop continues

      The "loop continues despite errors" stance is deliberate:
      the zero-zombie cleanup is best-effort, not strict — a
      transient FS race must not stop the cycle. *)
end
