(** Workspace_resilience — single source of truth for failure handling.

    Two sub-modules organise the resilience helpers:

    - {!Time}: monotonic-clock + ISO 8601 parsing.
    - {!Zombie}: historical Keeper-name convention helper.

    Renamed from [Resilience] (cycle 100 / fix #11709) so the module
    name does not shadow the [masc.resilience] sub-library that
    PR #11695 started using via [Resilience.Keeper_bridge].

    @since Single source of truth — failure handling consolidation *)

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

end

(** {1 Historical Keeper-name convention} *)

module Zombie : sig
  val is_keeper_name : string -> bool
  (** [is_keeper_name name] tests whether [name] matches the
      keeper convention [keeper-*-agent] (case-insensitive, trimmed). *)
end
