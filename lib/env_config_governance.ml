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
  (** GLM model label.  OAS cascade resolves "auto" to the concrete
      model via ZAI_DEFAULT_MODEL env var.
      MASC never hardcodes a model name — cascade is the SSOT. *)
  let default_model =
    get_string ~default:"auto" "MASC_GLM_DEFAULT_MODEL"

  let flash_model =
    get_string ~default:"auto" "MASC_GLM_FLASH_MODEL"
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

(** {1 Agent Autonomy Configuration}
    Primary env vars: MASC_AUTONOMY_*. *)

module Autonomy = struct
  let tick_interval_seconds =
    get_float ~default:2700.0 "MASC_AUTONOMY_TICK_INTERVAL_SEC"

  let agents_per_tick =
    get_int ~default:3 "MASC_AUTONOMY_AGENTS_PER_TICK"

  let max_posts_per_tick =
    get_int ~default:1 "MASC_AUTONOMY_MAX_POSTS_PER_TICK"

  let max_comments_per_tick =
    get_int ~default:3 "MASC_AUTONOMY_MAX_COMMENTS_PER_TICK"

  let max_daily_actions =
    get_int ~default:10 "MASC_AUTONOMY_MAX_DAILY_ACTIONS"

  let reflection_threshold =
    get_int ~default:100 "MASC_AUTONOMY_REFLECTION_THRESHOLD"

  let use_planner =
    get_bool ~default:true "MASC_AUTONOMY_USE_PLANNER"

  let enabled =
    get_bool ~default:true "MASC_AUTONOMY_ENABLED"

  let quiet_start =
    get_int ~default:3 "MASC_AUTONOMY_QUIET_START"

  let quiet_end =
    get_int ~default:7 "MASC_AUTONOMY_QUIET_END"

  let min_checkin_gap_seconds =
    get_float ~default:1800.0 "MASC_AUTONOMY_MIN_CHECKIN_GAP"

  let min_post_gap_seconds =
    get_float ~default:600.0 "MASC_AUTONOMY_MIN_POST_GAP"

  let min_comment_gap_seconds =
    get_float ~default:8.0 "MASC_AUTONOMY_MIN_COMMENT_GAP"

  let max_posts_per_day =
    get_int ~default:8 "MASC_AUTONOMY_MAX_POSTS_PER_DAY"

  let max_comments_per_day =
    get_int ~default:40 "MASC_AUTONOMY_MAX_COMMENTS_PER_DAY"

  (** Delegate MODEL calls to external Workers (Soul + Body pattern). *)
  let delegate_inference =
    get_bool ~default:false "MASC_DELEGATE_INFERENCE"
end

(** {1 Thompson Sampling / Agent Selection Configuration}
    Primary env vars: MASC_AUTONOMY_*. *)

module AgentSelection = struct
  let max_starvation_ticks =
    get_int ~default:12 "MASC_AUTONOMY_MAX_STARVATION_TICKS"

  let starvation_bonus_coefficient =
    get_float ~default:0.15 "MASC_AUTONOMY_STARVATION_BONUS_COEF"

  let thompson_weight =
    get_float ~default:0.7 "MASC_AUTONOMY_THOMPSON_WEIGHT"

  let use_model_selection =
    get_bool ~default:false "MASC_AUTONOMY_MODEL_SELECTION"

  let stats_persist_interval_s =
    get_float ~default:300.0 "MASC_AUTONOMY_STATS_PERSIST_INTERVAL"

  let vote_decay_factor =
    get_float ~default:0.95 "MASC_AUTONOMY_VOTE_DECAY_FACTOR"
end

(** {1 Timeouts & Buffer Sizes} *)

module Timeouts = struct
  (** GraphQL API call timeout (seconds).
      Used by keeper autonomy operations (curl to GraphQL endpoint). *)
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

(** {1 Operator Judge Configuration} *)

module Operator = struct
  (** Whether operator judge background loop is enabled. Default: true. *)
  let judge_enabled = get_bool ~default:true "MASC_OPERATOR_JUDGE_ENABLED"

  (** Operator judge interval, clamped to >= 15s. Default: 60. *)
  let judge_interval_sec = max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_INTERVAL_SEC")

  (** Room TTL for operator judge cleanup, clamped to >= 15s. Default: 60. *)
  let room_ttl_sec = max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_ROOM_TTL_SEC")

  (** Session TTL for operator judge cleanup, clamped to >= 30s. Default: 300. *)
  let session_ttl_sec = max 30 (get_int ~default:300 "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC")

  (** Operator snapshot cache TTL (seconds). Default: 30. *)
  let cache_ttl_sec = get_float ~default:30.0 "MASC_OPERATOR_CACHE_TTL"
end

(** {1 Dashboard Configuration} *)

module Dashboard_config = struct
  (** Whether dashboard fixtures are enabled. Default: false.
      Runtime-readable (tests change this via putenv). *)
  let fixtures_enabled () = get_bool ~default:false "MASC_DASHBOARD_FIXTURES_ENABLED"

  (** Dashboard fixture name override. *)
  let fixture_opt () =
    Sys.getenv_opt "MASC_DASHBOARD_FIXTURE" |> trim_opt

  (** Governance judge interval, clamped to >= 15s. Default: 60. *)
  let governance_judge_interval_sec =
    max 15 (get_int ~default:60 "MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC")

  (** Whether governance judge is enabled. Default: true. *)
  let governance_judge_enabled = get_bool ~default:true "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED"
end

(** {1 Model Routing Defaults} *)

module Model_defaults = struct
  (** Default cascade label (e.g. "gemini:pro,claude:sonnet"). *)
  let default_cascade_opt () =
    Sys.getenv_opt "MASC_DEFAULT_CASCADE" |> trim_opt

  (** Default provider name. *)
  let default_provider_opt () =
    Sys.getenv_opt "MASC_DEFAULT_PROVIDER" |> trim_opt

  (** Default model id. *)
  let default_model_opt () =
    Sys.getenv_opt "MASC_DEFAULT_MODEL" |> trim_opt

  (** Routing cascade for team session routing. Default: "routing_judge". *)
  let routing_cascade () =
    match Sys.getenv_opt "MASC_ROUTING_CASCADE" |> trim_opt with
    | Some s -> s
    | None -> "routing_judge"

  (** Goal models (comma-separated). *)
  let goal_models_opt () =
    Sys.getenv_opt "MASC_GOAL_MODELS" |> trim_opt

  (** Goal dispatch runtime. Default: "task". *)
  let goal_dispatch_runtime () =
    get_string ~default:"task" "MASC_GOAL_DISPATCH_RUNTIME"
end

(** {1 Endpoint Configuration} *)
