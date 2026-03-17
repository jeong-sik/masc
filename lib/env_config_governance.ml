open Env_config_core
open Env_config_runtime

module Guardian = struct
  (** Enable internal guardian loops (default: false) *)
  let enabled =
    get_bool ~default:false "MASC_GUARDIAN_ENABLED"

  (** Mode: masc | lodge | both *)
  let mode =
    get_string ~default:"masc" "MASC_GUARDIAN_MODE"

  (** Zombie cleanup interval (seconds) *)
  let zombie_interval_seconds =
    get_float ~default:Zombie.cleanup_interval_seconds "MASC_GUARDIAN_ZOMBIE_INTERVAL_SEC"

  (** GC interval (seconds); 0 disables *)
  let gc_interval_seconds =
    get_float ~default:3600.0 "MASC_GUARDIAN_GC_INTERVAL_SEC"

  (** GC threshold in days *)
  let gc_days =
    get_int ~default:7 "MASC_GUARDIAN_GC_DAYS"

  (** Lodge loop interval between runs (seconds) *)
  let lodge_interval_seconds =
    get_float ~default:300.0 "MASC_GUARDIAN_LODGE_INTERVAL_SEC"

  (** Lodge loop iterations per run *)
  let lodge_iterations =
    get_int ~default:10 "MASC_GUARDIAN_LODGE_ITERATIONS"

  (** Lodge loop delay between actions (ms) *)
  let lodge_delay_ms =
    get_int ~default:10000 "MASC_GUARDIAN_LODGE_DELAY_MS"

  (** Lodge loop verbose logging *)
  let lodge_verbose =
    get_bool ~default:false "MASC_GUARDIAN_LODGE_VERBOSE"

  (** Respect Lodge quiet hours *)
  let lodge_respect_quiet_hours =
    get_bool ~default:true "MASC_GUARDIAN_LODGE_RESPECT_QUIET_HOURS"
end

(** {1 LLM Configuration} *)

module Llm = struct
  (** Timeout for LLM API calls (seconds) *)
  let timeout_seconds =
    get_float ~default:30.0 "MASC_LLM_TIMEOUT_SEC"

  (** Integer fallback for call sites that use second granularity only. *)
  let timeout_seconds_int =
    max 1 (int_of_float timeout_seconds)

  (** Background operator judge timeout.
      Falls back to the global LLM timeout unless explicitly overridden. *)
  let operator_judge_timeout_seconds =
    max 5
      (get_int ~default:timeout_seconds_int "MASC_OPERATOR_JUDGE_TIMEOUT_SEC")

  (** Dashboard governance judge timeout.
      Falls back to the global LLM timeout unless explicitly overridden. *)
  let dashboard_governance_judge_timeout_seconds =
    max 5
      (get_int ~default:timeout_seconds_int
         "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC")

  (** Gardener LLM decision timeout.
      Falls back to the global LLM timeout unless explicitly overridden. *)
  let gardener_spawn_timeout_seconds =
    max 5
      (get_int ~default:timeout_seconds_int
         "MASC_GARDENER_SPAWN_LLM_TIMEOUT_SEC")

  (** Default GLM model for Z.ai API calls.
      Empty = let Glm_pool select at runtime. *)
  let default_model =
    get_string ~default:"glm-4.7" "MASC_GLM_DEFAULT_MODEL"

  (** Enable LLM response cache (L1+L2). *)
  let cache_enabled =
    get_bool ~default:true "MASC_LLM_CACHE_ENABLED"

  (** Default TTL for LLM response cache (seconds). *)
  let cache_ttl_seconds =
    get_int ~default:300 "MASC_LLM_CACHE_TTL_SEC"

  (** Skip caching for oversized prompts (character count). *)
  let cache_max_prompt_chars =
    get_int ~default:48000 "MASC_LLM_CACHE_MAX_PROMPT_CHARS"

  (** Cache only deterministic temperatures (default exact 0.0). *)
  let cache_max_temperature =
    get_float ~default:0.0 "MASC_LLM_CACHE_MAX_TEMP"

  (** L1 in-memory entry cap.
      BUG-015: Reduced from 2048 to 512 — unbounded growth with 2048 default
      caused excessive memory usage in long-running servers. *)
  let cache_l1_max_entries =
    get_int ~default:512 "MASC_LLM_CACHE_L1_MAX_ENTRIES"

  (** Spawn cache policy:
      - off
      - safe_only (GLM direct HTTP only, no MCP-tool side effects) *)
  let spawn_cache_policy =
    get_string ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
    |> String.trim
    |> String.lowercase_ascii

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

(** {1 Lodge Heartbeat v2 — Generative Agent Configuration} *)

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

  (** Delegate LLM calls to external Workers (Soul + Body pattern).
      When true, MASC emits heartbeat_task events instead of calling LLM directly.
      Workers subscribe to events and invoke the local llama runtime. *)
  let delegate_llm =
    get_bool ~default:false "MASC_DELEGATE_LLM"
end

(** {1 Social Runtime — Keeper-owned public-square activity} *)

module SocialRuntime = struct
  type strategy =
    | Event_driven
    | Periodic_sweep
    | Hybrid

  let enabled =
    get_bool ~default:true "MASC_SOCIAL_RUNTIME_ENABLED"

  let strategy =
    match
      Sys.getenv_opt "MASC_SOCIAL_STRATEGY"
      |> Option.map (fun value -> String.lowercase_ascii (String.trim value))
    with
    | Some "periodic_sweep" -> Periodic_sweep
    | Some "hybrid" -> Hybrid
    | _ -> Event_driven

  let strategy_to_string = function
    | Event_driven -> "event_driven"
    | Periodic_sweep -> "periodic_sweep"
    | Hybrid -> "hybrid"
end

(** {1 Lodge Selection — Thompson Sampling Configuration} *)

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

  (** Use LLM for final selection decision (experimental) *)
  let use_llm_selection =
    get_bool ~default:false "MASC_LODGE_LLM_SELECTION"

  (** Stats persistence interval (seconds) *)
  let stats_persist_interval_s =
    get_float ~default:300.0 "MASC_LODGE_STATS_PERSIST_INTERVAL"

  (** Vote decay factor for Beta prior updates.
      Applied to existing priors before adding new evidence.
      0.95 decay ~ 7-day half-life (0.95^168 = 0.0002). *)
  let vote_decay_factor =
    get_float ~default:0.95 "MASC_LODGE_VOTE_DECAY_FACTOR"
end

(** {1 Endpoint Configuration} *)
