(** Env_config_runtime_services — env-var-backed runtime service config
    (inference, rate limit, autonomy, agent selection, timeouts,
    dashboard, model defaults, anti-rationalization).

    All values cached at module-init from env vars; the cache
    means a runtime env-var change does not propagate without
    process restart.  The few [() -> X] re-readers for dashboard
    fixture selection are documented exceptions. *)

(** {1 Rate limit cleanup} *)

module RateLimit : sig
  val cleanup_interval_seconds : float
  (** [MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC] (default [300.0]). *)

  val entry_max_age_seconds : float
  (** [MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC] (default [3600.0]). *)
end

(** {1 Agent autonomy quiet hours} *)

module Autonomy : sig
  val quiet_start : int
  (** [MASC_AUTONOMY_QUIET_START] (default [3]).  Hour of day
      ([0..23]) when keeper suppresses actions. *)

  val quiet_end : int
  (** [MASC_AUTONOMY_QUIET_END] (default [7]). *)
end

(** {1 Thompson sampling agent selection} *)

module AgentSelection : sig
  val max_starvation_ticks : int
  (** [MASC_AUTONOMY_MAX_STARVATION_TICKS] (default [12]). *)

  val starvation_bonus_coefficient : float
  (** [MASC_AUTONOMY_STARVATION_BONUS_COEF] (default [0.15]). *)

  val thompson_weight : float
  (** [MASC_AUTONOMY_THOMPSON_WEIGHT] (default [0.7]). *)

  val vote_decay_factor : float
  (** [MASC_AUTONOMY_VOTE_DECAY_FACTOR] (default [0.95]). *)
end

(** {1 Timeouts} *)

module Timeouts : sig
  val maintenance_pulse_interval_sec : float
  (** [MASC_MAINTENANCE_PULSE_INTERVAL_SEC] (default [60.0]). Floor [1.0].
      Controls the orphan-observation and channel-dedup consumers. *)

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
