(** Env_config_runtime_services — env-var-backed runtime service config
    (inference, rate limit, autonomy, agent selection, timeouts,
    operator judge, dashboard, model defaults, anti-rationalization).

    All values cached at module-init from env vars; the cache
    means a runtime env-var change does not propagate without
    process restart.  The few [() -> X] re-readers for dashboard
    fixture selection are documented exceptions. *)

(** {1 Inference} *)

module Inference : sig
  val timeout_seconds : float
  (** [MASC_INFERENCE_TIMEOUT_SEC] (default [30.0]).  Timeout
      for model API calls. *)

  val cache_enabled : bool
  (** [MASC_INFERENCE_CACHE_ENABLED] feature flag.  Enable L1+L2
      response cache. *)

  val cache_ttl_seconds : int
  (** [MASC_INFERENCE_CACHE_TTL_SEC] (default [300]). *)

  val cache_max_prompt_chars : int
  (** [MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS] (default [48000]).
      Skip caching for oversized prompts (character count). *)

  val cache_max_temperature : float
  (** [MASC_INFERENCE_CACHE_MAX_TEMP] (default [0.0]).  Cache
      only deterministic temperatures (default exact [0.0]). *)

  val cache_l1_max_entries : int
  (** [MASC_INFERENCE_CACHE_L1_MAX_ENTRIES] (default [512]).
      L1 in-memory entry cap.  Reduced from 2048 (BUG-015) —
      unbounded growth at 2048 caused excessive memory in
      long-running servers. *)

  val spawn_cache_policy : string
  (** [MASC_SPAWN_CACHE_POLICY] (default ["safe_only"]).
      Trimmed + lowercased.  Two operator-visible values:
      - [["off"]]
      - [["safe_only"]] — GLM direct HTTP only, no MCP-tool
        side effects. *)
end

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
  val neo4j_timeout_sec : float
  (** [MASC_NEO4J_TIMEOUT_SEC] (default [60.0]).  Floor [1.0] —
      prevents tight-loop when misconfigured.  Controls the
      zero-zombie Pulse rhythm in the orchestrator. *)

end

(** {1 Operator judge} *)

module Operator : sig
  val judge_enabled : bool
  (** [MASC_OPERATOR_JUDGE_ENABLED] feature flag (default
      [true]). *)

  val judge_interval_sec : int
  (** [MASC_OPERATOR_JUDGE_INTERVAL_SEC] (default [60]).
      Floor [15s]. *)

  val workspace_ttl_sec : int
  (** [MASC_OPERATOR_JUDGE_WORKSPACE_TTL_SEC] (default [60]).
      Floor [15s]. *)

  val session_ttl_sec : int
  (** [MASC_OPERATOR_JUDGE_SESSION_TTL_SEC] (default [300]).
      Floor [30s]. *)

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
