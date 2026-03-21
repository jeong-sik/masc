open Env_config_core

(** {1 Inference Configuration} *)

module Inference = struct
  (** Timeout for model API calls (seconds) *)
  let timeout_seconds =
    get_float ~default:30.0 "MASC_INFERENCE_TIMEOUT_SEC"

  (** Integer fallback for call sites that use second granularity only. *)
  let timeout_seconds_int =
    max 1 (int_of_float timeout_seconds)

  (** Background operator judge timeout.
      Falls back to the global inference timeout unless explicitly overridden. *)
  let operator_judge_timeout_seconds =
    max 5
      (get_int ~default:timeout_seconds_int "MASC_OPERATOR_JUDGE_TIMEOUT_SEC")

  (** Dashboard governance judge timeout.
      Falls back to the global inference timeout unless explicitly overridden. *)
  let dashboard_governance_judge_timeout_seconds =
    max 5
      (get_int ~default:timeout_seconds_int
         "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC")

  (** Enable inference response cache (L1+L2). *)
  let cache_enabled =
    get_bool ~default:true "MASC_INFERENCE_CACHE_ENABLED"

  (** Default TTL for inference response cache (seconds). *)
  let cache_ttl_seconds =
    get_int ~default:300 "MASC_INFERENCE_CACHE_TTL_SEC"

  (** Skip caching for oversized prompts (character count). *)
  let cache_max_prompt_chars =
    get_int ~default:48000 "MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS"

  (** Cache only deterministic temperatures (default exact 0.0). *)
  let cache_max_temperature =
    get_float ~default:0.0 "MASC_INFERENCE_CACHE_MAX_TEMP"

  (** L1 in-memory entry cap.
      BUG-015: Reduced from 2048 to 512 — unbounded growth with 2048 default
      caused excessive memory usage in long-running servers. *)
  let cache_l1_max_entries =
    get_int ~default:512 "MASC_INFERENCE_CACHE_L1_MAX_ENTRIES"

  (** Spawn cache policy:
      - off
      - safe_only (GLM direct HTTP only, no MCP-tool side effects) *)
  let spawn_cache_policy =
    get_string ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
    |> String.trim
    |> String.lowercase_ascii
end

(** {1 GLM Configuration} *)

module Glm = struct
  (** Default GLM model for Z.ai API calls.
      Empty = let GLM provider select at runtime. *)
  let default_model =
    get_string ~default:"glm-4.7" "MASC_GLM_DEFAULT_MODEL"

  (** Default GLM flash model for lightweight tasks.
      Empty = provider decides. *)
  let flash_model =
    get_string ~default:"glm-4.7-flash" "MASC_GLM_FLASH_MODEL"
end

(** {1 Gemini Configuration} *)

module Gemini = struct
  (** Default Gemini model.
      Empty = skip Gemini in cascades unless env-var overridden. *)
  let default_model =
    get_string ~default:"gemini-2.5-pro" "MASC_GEMINI_DEFAULT_MODEL"

  (** Gemini flash model for lightweight tasks.
      Empty = skip Gemini flash in cascades. *)
  let flash_model =
    get_string ~default:"gemini-2.5-flash" "MASC_GEMINI_FLASH_MODEL"
end

(** {1 Claude Configuration} *)

module Claude = struct
  (** Default Claude model.
      Empty = skip Claude in cascades unless env-var overridden. *)
  let default_model =
    get_string ~default:"claude-sonnet-4-6" "MASC_CLAUDE_DEFAULT_MODEL"
end

(** {1 OpenAI Configuration} *)

module OpenAI = struct
  (** Default OpenAI model.
      Empty = skip OpenAI in cascades unless env-var overridden. *)
  let default_model =
    get_string ~default:"gpt-4.1" "MASC_OPENAI_DEFAULT_MODEL"
end

(** {1 Rate Limit Cleanup Configuration} *)

module RateLimit = struct
  (** Cleanup interval for stale rate limit buckets (seconds) *)
  let cleanup_interval_seconds =
    get_float ~default:300.0 "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC"

  (** Max age for rate limit entries before cleanup (seconds) *)
  let entry_max_age_seconds =
    get_float ~default:3600.0 "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC"
end

(** {1 Agent Autonomy Configuration (env vars retain MASC_LODGE_* prefix for backward compat)} *)

module LodgeV2 = struct
  (** Tick interval: 45 min default (configurable via MASC_LODGE_TICK_INTERVAL_SEC) *)
  let tick_interval_seconds =
    get_float ~default:2700.0 "MASC_LODGE_TICK_INTERVAL_SEC"

  (** How many agents to activate per tick *)
  let agents_per_tick =
    get_int ~default:3 "MASC_LODGE_AGENTS_PER_TICK"

  (** Max posts an agent can make per tick *)
  let max_posts_per_tick =
    get_int ~default:1 "MASC_LODGE_MAX_POSTS_PER_TICK"

  (** Max comments an agent can make per tick *)
  let max_comments_per_tick =
    get_int ~default:3 "MASC_LODGE_MAX_COMMENTS_PER_TICK"

  (** Max total actions per agent per day *)
  let max_daily_actions =
    get_int ~default:10 "MASC_LODGE_MAX_DAILY_ACTIONS"

  (** Importance sum threshold to trigger reflection *)
  let reflection_threshold =
    get_int ~default:100 "MASC_LODGE_REFLECTION_THRESHOLD"

  (** Use plan-based agent selection (vs legacy round-robin) *)
  let use_planner =
    get_bool ~default:true "MASC_LODGE_USE_PLANNER"

  (** Enable heartbeat *)
  let enabled =
    get_bool ~default:true "MASC_LODGE_ENABLED"

  (** Quiet hours start (KST, inclusive) *)
  let quiet_start =
    get_int ~default:3 "MASC_LODGE_QUIET_START"

  (** Quiet hours end (KST, exclusive) *)
  let quiet_end =
    get_int ~default:7 "MASC_LODGE_QUIET_END"

  (** Min gap between same agent check-ins (seconds) *)
  let min_checkin_gap_seconds =
    get_float ~default:1800.0 "MASC_LODGE_MIN_CHECKIN_GAP"

  (** Min gap between posts by the same agent (seconds).
      Default 600s (10 min). Lower than per-tick limit for finer control. *)
  let min_post_gap_seconds =
    get_float ~default:600.0 "MASC_LODGE_MIN_POST_GAP"

  (** Min gap between comments by the same agent (seconds). *)
  let min_comment_gap_seconds =
    get_float ~default:8.0 "MASC_LODGE_MIN_COMMENT_GAP"

  (** Max posts per agent per day. *)
  let max_posts_per_day =
    get_int ~default:8 "MASC_LODGE_MAX_POSTS_PER_DAY"

  (** Max comments per agent per day. *)
  let max_comments_per_day =
    get_int ~default:40 "MASC_LODGE_MAX_COMMENTS_PER_DAY"

  (** Delegate MODEL calls to external Workers (Soul + Body pattern).
      When true, MASC emits heartbeat_task events instead of calling MODEL directly.
      Workers subscribe to events and invoke the local llama runtime. *)
  let delegate_inference =
    get_bool ~default:false "MASC_DELEGATE_INFERENCE"
end

(** {1 Thompson Sampling Configuration (env vars retain MASC_LODGE_* prefix for backward compat)} *)

module LodgeSelection = struct
  (** Max ticks without selection before forced inclusion (starvation rescue).
      With 4h ticks, 12 ticks = 48 hours max inactivity. *)
  let max_starvation_ticks =
    get_int ~default:12 "MASC_LODGE_MAX_STARVATION_TICKS"

  (** Coefficient for logarithmic starvation bonus.
      bonus = coefficient * ln(1 + ticks_since_selection) *)
  let starvation_bonus_coefficient =
    get_float ~default:0.15 "MASC_LODGE_STARVATION_BONUS_COEF"

  (** Weight for Thompson score in final selection (0-1).
      Remaining weight goes to starvation bonus.
      Higher = more quality-driven, lower = more fairness-driven. *)
  let thompson_weight =
    get_float ~default:0.7 "MASC_LODGE_THOMPSON_WEIGHT"

  (** Use MODEL for final selection decision (experimental) *)
  let use_model_selection =
    get_bool ~default:false "MASC_LODGE_MODEL_SELECTION"

  (** Stats persistence interval (seconds) *)
  let stats_persist_interval_s =
    get_float ~default:300.0 "MASC_LODGE_STATS_PERSIST_INTERVAL"

  (** Vote decay factor for Beta prior updates.
      Applied to existing priors before adding new evidence.
      0.95 decay ~ 7-day half-life (0.95^168 = 0.0002). *)
  let vote_decay_factor =
    get_float ~default:0.95 "MASC_LODGE_VOTE_DECAY_FACTOR"
end

(** {1 Timeouts & Buffer Sizes} *)

module Timeouts = struct
  (** GraphQL API call timeout (seconds).
      Used by lodge agent operations (curl to GraphQL endpoint). *)
  let graphql_timeout_sec =
    get_float ~default:30.0 "MASC_GRAPHQL_TIMEOUT_SEC"

  (** Neo4j / zombie-cleanup interval (seconds).
      Controls the zero-zombie Pulse rhythm in the orchestrator.
      Clamped to >= 1.0 to prevent tight-loop when misconfigured. *)
  let neo4j_timeout_sec =
    Float.max 1.0 (get_float ~default:60.0 "MASC_NEO4J_TIMEOUT_SEC")

  (** Agent crash-recovery timeout (seconds).
      Agents with no heartbeat beyond this threshold are considered crashed. *)
  let agent_timeout_sec =
    get_float ~default:360.0 "MASC_AGENT_TIMEOUT_SEC"

  (** SSE keepalive interval (seconds).
      Frequency of `: keepalive` frames on command-plane SSE streams.
      Clamped to >= 1.0 to prevent tight-loop when misconfigured. *)
  let sse_keepalive_sec =
    Float.max 1.0 (get_float ~default:30.0 "MASC_SSE_KEEPALIVE_SEC")

  (** A2A event buffer size per subscription.
      Caps the in-memory event list to prevent unbounded growth. *)
  let event_buffer_size =
    get_int ~default:100 "MASC_EVENT_BUFFER_SIZE"
end

(** {1 Endpoint Configuration} *)
