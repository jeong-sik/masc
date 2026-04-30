(** Env_config_governance — env-var-backed governance config
    (inference, rate limit, autonomy, agent selection, timeouts,
    operator judge, dashboard, model defaults, anti-rationalization).

    All values cached at module-init from env vars; the cache
    means a runtime env-var change does not propagate without
    process restart.  The few [() -> X] re-readers (for the
    dashboard fixtures path and command-plane snapshot
    refresh) are documented exceptions. *)

(** {1 Inference} *)

module Inference : sig
  val timeout_seconds : float
  (** [MASC_INFERENCE_TIMEOUT_SEC] (default [30.0]).  Timeout
      for model API calls. *)

  val timeout_seconds_int : int
  (** [max 1 (int_of_float timeout_seconds)] — convenience for
      callers that need second granularity only. *)

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

  val sse_keepalive_sec : float
  (** [MASC_SSE_KEEPALIVE_SEC] (default [30.0]).  Floor [1.0]. *)

  val event_buffer_size : int
  (** [MASC_EVENT_BUFFER_SIZE] (default [100]).  A2A event
      buffer cap per subscription. *)
end

(** {1 Operator judge} *)

module Operator : sig
  val judge_enabled : bool
  (** [MASC_OPERATOR_JUDGE_ENABLED] feature flag (default
      [true]). *)

  val judge_interval_sec : int
  (** [MASC_OPERATOR_JUDGE_INTERVAL_SEC] (default [60]).
      Floor [15s]. *)

  val room_ttl_sec : int
  (** [MASC_OPERATOR_JUDGE_ROOM_TTL_SEC] (default [60]).
      Floor [15s]. *)

  val session_ttl_sec : int
  (** [MASC_OPERATOR_JUDGE_SESSION_TTL_SEC] (default [300]).
      Floor [30s]. *)

  val cache_ttl_sec : float
  (** [MASC_OPERATOR_CACHE_TTL] (default [30.0]).  Operator
      snapshot cache TTL. *)
end

(** {1 Dashboard} *)

module Dashboard_config : sig
  val fixtures_enabled : unit -> bool
  (** [MASC_DASHBOARD_FIXTURES_ENABLED] feature flag.
      Re-readable within the process — does NOT imply
      shell-level hot reload as an operator contract. *)

  val command_plane_snapshot_refresh_enabled : unit -> bool
  (** [MASC_COMMAND_PLANE_SNAPSHOT_REFRESH_ENABLED] feature
      flag.  Default [false] because large roots can make the
      full snapshot too heavy for always-on background
      refresh. *)

  val command_plane_snapshot_cache_ttl_s : unit -> float
  (** [MASC_COMMAND_PLANE_SNAPSHOT_CACHE_TTL_S] (default
      [30.0]).  Floor [5.0]. *)

  val fixture_opt : unit -> string option

  val governance_judge_interval_sec : int
  (** [MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC] (default
      [60]).  Floor [15s]. *)

  val governance_judge_enabled : bool
  (** [MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED] feature flag
      (default [true]). *)
end

(** {1 Model routing defaults} *)

module Model_defaults : sig
  val default_cascade_opt : unit -> string option
  val default_provider_opt : unit -> string option
  val default_model_opt : unit -> string option
  val routing_cascade : unit -> string
  (** [MASC_ROUTING_CASCADE] override, otherwise logical key ["routing"]. *)

  val goal_models_opt : unit -> string option
  val goal_dispatch_runtime : unit -> string
  (** [MASC_GOAL_DISPATCH_RUNTIME] (default ["task"]). *)
end

(** {1 Anti-rationalization} *)

module AntiRationalization : sig
  type fail_mode =
    | Open
    | Closed

  val fail_mode_of_string : string -> fail_mode
  (** Parses operator-visible aliases:
      [["closed"]] / [["reject"]] / [["fail_closed"]] /
      [["deny"]] → [Closed]; everything else → [Open].  Default
      bias is intentional (#9794): when the verifier LLM is
      unavailable, the historical behavior is to approve by
      default (favor liveness). *)

  val fail_mode_to_string : fail_mode -> string
  (** [Open -> "open"] / [Closed -> "closed"]. *)

  val fail_mode : fail_mode
  (** [MASC_ANTI_RATIONALIZATION_FAIL_MODE] (default
      [["open"]]).  Fail mode for gate 3 (LLM-unavailable
      branch). *)

  val gate2_fail_closed : bool
  (** [MASC_ANTI_RATIONALIZATION_GATE2_FAIL_CLOSED] (default
      [false] since #10113).

      Gate 2 (substring excuse pattern) historically issued a
      terminal Reject before the LLM evaluator ever saw the
      notes.  Substring matching has no word-boundary or
      context awareness, so legitimate notes like "filed a
      follow-up issue" or "fixed primary path; pre-existing
      issue #1234 tracked separately" were rejected and
      keepers learned to sanitize vocabulary instead of
      describing work honestly.

      With [false] (default), substring detection becomes an
      advisory hint that travels into the LLM evaluator
      prompt, and the LLM makes the final decision with full
      context.  Operators who want a local fail-closed safety
      net (e.g. running without a reliable LLM evaluator) can
      flip to [true].

      Independent from {!fail_mode} which only governs the
      LLM-unavailable branch at gate 3. *)
end
