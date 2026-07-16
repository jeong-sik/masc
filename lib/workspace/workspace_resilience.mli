(** Workspace_resilience — single source of truth for failure handling.

    Two sub-modules organise the resilience helpers:

    - {!Time}: monotonic-clock + ISO 8601 parsing.
    - {!Zombie}: agent-staleness detection with per-class thresholds
      (regular vs keeper agents).

    Renamed from [Resilience] (cycle 100 / fix #11709) so the module
    name does not shadow the [masc.resilience] sub-library that
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

  val is_keeper_record :
    agent_type:string -> agent_meta:Masc_domain.agent_meta option -> bool
  (** [is_keeper_record ~agent_type ~agent_meta] returns [true] only for
      file-backed evidence that the agent is a keeper: [agent_type =
      "keeper"] or keeper-owned metadata. Keeper-shaped names are not
      authority and do not receive keeper grace on their own. *)

  val is_keeper :
    name:string -> agent_type:string -> bool
  (** [is_keeper ~name ~agent_type] is a compatibility wrapper for callers
      that do not have metadata. The [name] argument is intentionally ignored
      for keeper-grace decisions; only [agent_type = "keeper"] is accepted. *)

  val is_zombie_for_agent :
    ?keeper_threshold_sec:float ->
    ?agent_threshold_sec:float ->
    ?agent_type:string ->
    ?agent_meta:Masc_domain.agent_meta ->
    agent_name:string ->
    string ->
    bool
  (** [is_zombie_for_agent ?keeper_threshold_sec ?agent_threshold_sec
      ?agent_type ?agent_meta ~agent_name last_seen_iso] uses
      {!Env_config_runtime.Zombie.keeper_threshold_seconds} when
      {!is_keeper_record} has typed/metadata evidence that the agent is a
      keeper, otherwise falls back to {!default_zombie_threshold}. Callers may
      override both thresholds for deterministic tests or one-off cleanup
      windows. This is the canonical "should I evict this agent" predicate for
      audit, status, and cleanup consumers. *)
end
