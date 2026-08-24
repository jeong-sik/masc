(** Env_config_runtime_services — env-var-backed runtime service config
    (inference, rate limit, autonomy, agent selection, timeouts,
    dashboard, model defaults, anti-rationalization).

    All values cached at module-init from env vars; the cache
    means a runtime env-var change does not propagate without
    process restart.  The [() -> X] re-readers for OAuth request policy and
    dashboard fixture selection are documented exceptions. *)

(** {1 OAuth} *)

module OAuth : sig
  val enabled : unit -> bool
  val code_ttl_sec : unit -> int
  val access_token_ttl_sec : unit -> int
  val refresh_token_ttl_sec : unit -> int
  val max_pending_codes : unit -> int
  val max_clients : unit -> int

  (** OAuth policy is re-read at request boundaries. Integer values must be
      positive; malformed or non-positive input is reported and falls back to
      the documented default. *)
end

(** {1 Rate limit cleanup} *)

module RateLimit : sig
  val cleanup_interval_seconds : float
  (** [MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC] (default [300.0]). *)

  val entry_max_age_seconds : float
  (** [MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC] (default [3600.0]). *)
end

(** {1 Timeouts} *)

module Timeouts : sig
  val maintenance_pulse_interval_sec : float
  (** [MASC_MAINTENANCE_PULSE_INTERVAL_SEC] (default [60.0]). Floor [1.0].
      Controls the orphan-observation and channel-dedup consumers, and bounds
      completion-authority retry delay. *)

end

(** {1 Schedule runner} *)

module ScheduleRunner : sig
  val interval_sec : float
  (** [MASC_SCHEDULE_RUNNER_INTERVAL_SEC] (default [15.0]). Floor [1.0].
      Poll cadence of the schedule runner; a poll granularity, not a
      wake authority. *)

  val clamp_interval_sec : float -> float
  (** Applies the [1.0] floor to a candidate interval. Exposed for
      in-process floor-contract tests; [interval_sec] is the applied value. *)

end

(** {1 Operator snapshot cache} *)

module Operator : sig
  val cache_ttl_sec : float
  (** [MASC_OPERATOR_CACHE_TTL] (default [30.0]).  Operator
      snapshot cache TTL. *)

  val cache_stale_grace_factor : float
  (** [MASC_OPERATOR_CACHE_STALE_GRACE_FACTOR] (default [3.0]).
      Multiplier applied to [cache_ttl_sec] to determine how long a
      stale snapshot is served while recomputing in the background. *)

  val cache_background_revalidate : bool
  (** [MASC_OPERATOR_CACHE_BACKGROUND_REVALIDATE] feature flag
      (default [true]). When [false], stale entries block on recompute
      like the original TTL cache. *)
end

(** {1 Dashboard} *)

module Dashboard_config : sig
  val fixtures_enabled : unit -> bool
  (** [MASC_DASHBOARD_FIXTURES_ENABLED] feature flag.
      Re-readable within the process — does NOT imply
      shell-level hot reload as an operator contract. *)

  val fixture_opt : unit -> string option

end

(** {1 Model routing defaults} *)

module Model_defaults : sig
  val default_runtime_opt : unit -> string option
end
