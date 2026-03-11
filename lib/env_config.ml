(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    Usage:
      let threshold = Env_config.Zombie.threshold_seconds
      let lock_timeout = Env_config.Lock.timeout_seconds
*)

(** Safe getters with defaults *)
let get_string ~default name =
  match Sys.getenv_opt name with
  | Some v -> v
  | None -> default

let get_int ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.int_of_string_with_default ~default v
  | None -> default

let get_float ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.float_of_string_with_default ~default v
  | None -> default

let get_bool ~default name =
  match Sys.getenv_opt name with
  | Some v ->
      (match String.lowercase_ascii v with
       | "true" | "1" | "yes" -> true
       | "false" | "0" | "no" -> false
       | _ -> default)
  | None -> default

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let strip_trailing_slashes value =
  let rec loop idx =
    if idx <= 0 then ""
    else if value.[idx - 1] = '/' then loop (idx - 1)
    else String.sub value 0 idx
  in
  loop (String.length value)

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let existing_file path =
  Sys.file_exists path && not (Sys.is_directory path)

let home_dir_opt () =
  Sys.getenv_opt "HOME" |> trim_opt

let me_root_opt () =
  match Sys.getenv_opt "MASC_WORKSPACE_ROOT" |> trim_opt with
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "ME_ROOT" |> trim_opt with
      | Some path -> Some path
      | None -> Sys.getenv_opt "DUNE_SOURCEROOT" |> trim_opt)

let me_root () =
  match me_root_opt () with
  | Some path -> path
  | None -> failwith "MASC_WORKSPACE_ROOT or ME_ROOT is required (tests may use DUNE_SOURCEROOT)"

let sb_path_opt () =
  match Sys.getenv_opt "MASC_SB_PATH" |> trim_opt with
  | Some path -> Some path
  | None -> (
      match me_root_opt () with
      | Some root ->
          let path = Filename.concat root "scripts/sb" in
          if existing_file path then Some path else None
      | None -> None)

let sb_path () =
  match sb_path_opt () with
  | Some path -> path
  | None -> failwith "Unable to resolve scripts/sb. Set MASC_SB_PATH or MASC_WORKSPACE_ROOT."

let masc_http_port () =
  match Sys.getenv_opt "MASC_HTTP_PORT" |> trim_opt with
  | Some port -> port
  | None -> (
      match Sys.getenv_opt "MASC_PORT" |> trim_opt with
      | Some port -> port
      | None -> "8935")

let masc_http_base_url () =
  match Sys.getenv_opt "MASC_HTTP_BASE_URL" |> trim_opt with
  | Some base -> strip_trailing_slashes base
  | None ->
      let host =
        match Sys.getenv_opt "MASC_HOST" |> trim_opt with
        | Some value -> value
        | None -> failwith "MASC_HTTP_BASE_URL is required (or set MASC_HOST with MASC_HTTP_PORT/MASC_PORT)"
      in
      Printf.sprintf "http://%s:%s" host (masc_http_port ())

let libdatachannel_path_candidates () =
  let env_path =
    Sys.getenv_opt "LIBDATACHANNEL_PATH" |> trim_opt |> Option.to_list
  in
  let common =
    [
      "/usr/local/lib/libdatachannel.dylib";
      "/opt/homebrew/lib/libdatachannel.dylib";
      "/usr/lib/libdatachannel.dylib";
      "/usr/local/lib/libdatachannel.so";
      "/usr/lib/libdatachannel.so";
    ]
  in
  let home_local =
    match home_dir_opt () with
    | Some home -> [ Filename.concat home "local/lib/libdatachannel.dylib" ]
    | None -> []
  in
  env_path @ common @ home_local

let libdatachannel_path_opt () =
  libdatachannel_path_candidates ()
  |> List.find_opt existing_file

(** {1 Zombie Detection / Cleanup Configuration} *)

module Zombie = struct
  (** Threshold for considering a resource as zombie (seconds) *)
  let threshold_seconds =
    get_float ~default:300.0 "MASC_ZOMBIE_THRESHOLD_SEC"

  (** Threshold for keeper agents (longer grace period, default 1 hour) *)
  let keeper_threshold_seconds =
    get_float ~default:3600.0 "MASC_KEEPER_ZOMBIE_THRESHOLD_SEC"

  (** Cleanup loop interval (seconds) *)
  let cleanup_interval_seconds =
    get_float ~default:60.0 "MASC_ZOMBIE_CLEANUP_INTERVAL_SEC"
end

(** {1 Lock Configuration} *)

module Lock = struct
  (** Default lock timeout (seconds) *)
  let timeout_seconds =
    get_float ~default:1800.0 "MASC_LOCK_TIMEOUT_SEC"

  (** Lock expiry warning threshold (seconds before expiry) *)
  let expiry_warning_seconds =
    get_float ~default:300.0 "MASC_LOCK_EXPIRY_WARNING_SEC"
end

(** {1 Session Configuration} *)

module Session = struct
  (** Maximum session age before cleanup (seconds) *)
  let max_age_seconds =
    get_float ~default:3600.0 "MASC_SESSION_MAX_AGE_SEC"

  (** Rate limit window (seconds) *)
  let rate_limit_window_seconds =
    get_float ~default:60.0 "MASC_SESSION_RATE_LIMIT_WINDOW_SEC"
end

(** {1 Tempo (Polling Interval) Configuration} *)

module Tempo = struct
  (** Minimum polling interval (seconds) - for urgent tempo *)
  let min_interval_seconds =
    get_float ~default:60.0 "MASC_TEMPO_MIN_INTERVAL_SEC"

  (** Maximum polling interval (seconds) - for idle tempo *)
  let max_interval_seconds =
    get_float ~default:600.0 "MASC_TEMPO_MAX_INTERVAL_SEC"

  (** Default polling interval (seconds) *)
  let default_interval_seconds =
    get_float ~default:300.0 "MASC_TEMPO_DEFAULT_INTERVAL_SEC"
end

(** {1 Orchestrator Configuration} *)

module Orchestrator = struct
  (** Orchestrator check interval (seconds) *)
  let check_interval_seconds =
    get_float ~default:300.0 "MASC_ORCHESTRATOR_INTERVAL"

  (** Orchestrator agent name *)
  let agent_name =
    get_string ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"
end

(** {1 Mitosis (Cell Division) Configuration} *)

module Mitosis = struct
  (** Time-based trigger interval (seconds) *)
  let trigger_interval_seconds =
    get_float ~default:300.0 "MASC_MITOSIS_INTERVAL_SEC"

  (** Cooldown between consecutive handoffs (seconds).
      Prevents rapid repeated handoffs when context_ratio fluctuates near threshold. *)
  let handoff_cooldown_seconds =
    get_float ~default:60.0 "MASC_MITOSIS_HANDOFF_COOLDOWN_SEC"

  (** Enable experimental mitosis path (A/B testing integration).
      When true, run_sync_handoff logs the experimental path and can
      participate in experiment flag checks. *)
  let experiment_enabled =
    get_bool ~default:false "MASC_MITOSIS_EXPERIMENT_ENABLED"

  (** Enable adaptive threshold learning from handoff outcomes.
      When true, thresholds are adjusted via EMA based on handoff quality signals.
      Persisted per room in ~/.masc/adaptive_thresholds_{room}.json.
      Default: false (safe rollout — uses static thresholds until enabled). *)
  let adaptive_thresholds_enabled =
    get_bool ~default:false "MASC_ADAPTIVE_THRESHOLDS_ENABLED"
end

(** {1 Spawn Configuration} *)

module Spawn = struct
  (** Default spawn timeout for agent processes (seconds).
      Used by spawn.ml, spawn_eio.ml, tool_mitosis.ml, and tool_relay.ml.
      Higher value (600s) allows for slow network/API conditions while preventing indefinite hangs. *)
  let timeout_seconds =
    int_of_float (get_float ~default:600.0 "MASC_SPAWN_TIMEOUT_SEC")

  (** Extended timeout for perpetual coding mode (seconds).
      Used when perpetual_loop spawns coding agents. Default 2 hours. *)
  let coding_timeout_seconds =
    int_of_float (get_float ~default:7200.0 "MASC_SPAWN_CODING_TIMEOUT_SEC")

  (** Grace period before timeout — sends SIGTERM for checkpoint opportunity (seconds). *)
  let grace_period_seconds =
    int_of_float (get_float ~default:60.0 "MASC_SPAWN_GRACE_PERIOD_SEC")
end

(** {1 Local LLM Server Configuration} *)

module Llama = struct
  (** OpenAI-compatible llama.cpp server URL *)
  let server_url =
    get_string ~default:"http://127.0.0.1:8085" "LLAMA_SERVER_URL"

  (** Default local runtime model id for llama.cpp/OpenAI-compatible servers. *)
  let default_model =
    get_string ~default:"explicit-model-required" "LLAMA_DEFAULT_MODEL"
end

(** {1 Federation Configuration} *)

module Federation = struct
  (** Cross-cluster request timeout (seconds) *)
  let timeout_seconds =
    get_float ~default:3600.0 "MASC_FEDERATION_TIMEOUT_SEC"
end

(** {1 Cancellation Token Configuration} *)

module Cancellation = struct
  (** Token cleanup max age (seconds) *)
  let token_max_age_seconds =
    get_float ~default:3600.0 "MASC_CANCELLATION_TOKEN_MAX_AGE_SEC"
end

(** {1 Internal Guardian Configuration} *)

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

  (** Default GLM model for Z.ai API calls *)
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

  (** L1 in-memory entry cap. *)
  let cache_l1_max_entries =
    get_int ~default:2048 "MASC_LLM_CACHE_L1_MAX_ENTRIES"

  (** Spawn cache policy:
      - off
      - safe_only (GLM direct HTTP only, no MCP-tool side effects) *)
  let spawn_cache_policy =
    get_string ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
    |> String.trim
    |> String.lowercase_ascii
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

  (** Delegate LLM calls to external Workers (Soul + Body pattern).
      When true, MASC emits heartbeat_task events instead of calling LLM directly.
      Workers subscribe to events and invoke the local llama runtime. *)
  let delegate_llm =
    get_bool ~default:false "MASC_DELEGATE_LLM"
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

module Endpoints = struct
  (** @deprecated LLM-MCP server URL - no longer used.
      Use {!Llm_client.run_prompt_cascade} with {!Lodge_cascade.get_cascade}
      instead. Kept for backward compatibility; will be removed in v3.0. *)
  let llm_mcp_url =
    get_string ~default:"" "LLM_MCP_URL"  (* Default empty - not used *)

  (** MASC server host *)
  let masc_host () =
    match Uri.host (Uri.of_string (masc_http_base_url ())) with
    | Some host -> host
    | None -> failwith "MASC_HTTP_BASE_URL must include a host"

  (** MASC server port *)
  let masc_port () =
    match Uri.port (Uri.of_string (masc_http_base_url ())) with
    | Some port -> port
    | None -> (
        match Uri.scheme (Uri.of_string (masc_http_base_url ())) with
        | Some "https" -> 443
        | Some "http" -> 80
        | _ -> failwith "MASC_HTTP_BASE_URL must include a port or scheme")

  (** MASC SSE URL (derived) *)
  let masc_sse_url () =
    Printf.sprintf "%s/sse" (masc_http_base_url ())
end

(** {1 Gardener — Self-Organizing Agent Ecosystem} *)

module Gardener = struct
  (** Master switch for Gardener Agent *)
  let enabled =
    get_bool ~default:false "MASC_GARDENER_ENABLED"

  (** Minimum agent population (never retire below this) *)
  let min_agents =
    get_int ~default:5 "MASC_GARDENER_MIN_AGENTS"

  (** Maximum agent population (never spawn above this) *)
  let max_agents =
    get_int ~default:30 "MASC_GARDENER_MAX_AGENTS"

  (** Target agent population (homeostatic sweet spot) *)
  let target_agents =
    get_int ~default:15 "MASC_GARDENER_TARGET_AGENTS"

  (** Maximum spawns allowed per day *)
  let max_daily_spawns =
    get_int ~default:3 "MASC_GARDENER_MAX_DAILY_SPAWNS"

  (** Maximum retirements allowed per day *)
  let max_daily_retirements =
    get_int ~default:2 "MASC_GARDENER_MAX_DAILY_RETIREMENTS"

  (** Minimum time between spawns (seconds) *)
  let spawn_cooldown_sec =
    get_float ~default:3600.0 "MASC_GARDENER_SPAWN_COOLDOWN_SEC"

  (** Minimum time between retirements (seconds) *)
  let retirement_cooldown_sec =
    get_float ~default:7200.0 "MASC_GARDENER_RETIREMENT_COOLDOWN_SEC"

  (** Use LLM for complex spawn/retire decisions *)
  let use_llm_decision =
    get_bool ~default:true "MASC_GARDENER_USE_LLM"

  (** Minimum hours before a gap signal can trigger spawn *)
  let gap_maturity_hours =
    get_float ~default:2.0 "MASC_GARDENER_GAP_MATURITY_HOURS"

  (** Hours of inactivity before an agent is retirement-eligible *)
  let idle_threshold_hours =
    get_float ~default:48.0 "MASC_GARDENER_IDLE_THRESHOLD_HOURS"

  (** Grace period before actual retirement (seconds) *)
  let retirement_grace_sec =
    get_float ~default:3600.0 "MASC_GARDENER_RETIREMENT_GRACE_SEC"

  (** Consecutive failures before circuit breaker opens *)
  let max_consecutive_failures =
    get_int ~default:3 "MASC_GARDENER_MAX_FAILURES"

  (** Circuit breaker open duration (seconds) *)
  let circuit_cooldown_sec =
    get_float ~default:3600.0 "MASC_GARDENER_CIRCUIT_COOLDOWN_SEC"

  (** Health check interval (seconds) *)
  let check_interval_sec =
    get_float ~default:1800.0 "MASC_GARDENER_CHECK_INTERVAL_SEC"
end

(** {1 Keeper Bootstrap Configuration} *)

module KeeperBootstrap = struct
  (** Enable startup keeper bootstrap scan *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_BOOTSTRAP_ENABLED"

  (** Keeper considered stale when last turn exceeds this threshold (seconds) *)
  let stale_turn_seconds =
    get_float ~default:3600.0 "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC"

  (** Max keeper meta files to scan during bootstrap *)
  let max_scan =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_SCAN"

  (** Backward compatibility: legacy field for call sites not yet migrated
      from pre-dynamic-sharding versions. Keep alias for max_scan. *)
  let max_active_keepers =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
end

(** {1 Keeper Interesting Alert Configuration} *)

module KeeperAlert = struct
  (** Master switch for keeper interesting alert detection/fanout *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_ENABLED"

  (** Minimum score required to trigger alert fanout *)
  let min_score =
    get_float ~default:0.70 "MASC_KEEPER_ALERT_MIN_SCORE"

  (** Maximum alert body chars used for external fanout payloads *)
  let max_body_chars =
    get_int ~default:1200 "MASC_KEEPER_ALERT_MAX_BODY_CHARS"

  (** Retry count for each fanout channel (in addition to initial attempt) *)
  let max_retries =
    get_int ~default:2 "MASC_KEEPER_ALERT_MAX_RETRIES"

  (** Base retry delay in milliseconds (exponential backoff) *)
  let retry_base_delay_ms =
    get_int ~default:250 "MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS"

  (** Board fanout configuration *)
  let board_enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_BOARD_ENABLED"

  let board_author =
    get_string ~default:"keeper-alert-bot" "MASC_KEEPER_ALERT_BOARD_AUTHOR"

  let board_hearth =
    get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_BOARD_HEARTH"

  let board_visibility =
    get_string ~default:"internal" "MASC_KEEPER_ALERT_BOARD_VISIBILITY"

  (** Slack fanout configuration *)
  let slack_enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_SLACK_ENABLED"

  let slack_webhook_url =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL"

  (** Slack DM fanout configuration *)
  let slack_dm_enabled =
    get_bool ~default:false "MASC_KEEPER_ALERT_SLACK_DM_ENABLED"

  let slack_dm_user_id =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_DM_USER_ID"

  (** GitHub issue fanout configuration *)
  let github_enabled =
    get_bool ~default:false "MASC_KEEPER_ALERT_GITHUB_ENABLED"

  let github_repo =
    get_string ~default:"" "MASC_KEEPER_ALERT_GITHUB_REPO"

  let github_label =
    get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_GITHUB_LABEL"

  let github_min_score =
    get_float ~default:0.85 "MASC_KEEPER_ALERT_GITHUB_MIN_SCORE"
end

module Sentinel = struct
  let enabled = get_bool ~default:true "MASC_SENTINEL_ENABLED"
  let heartbeat_interval_sec = get_float ~default:30.0 "MASC_SENTINEL_HEARTBEAT_SEC"
  let board_patrol_interval_sec = get_float ~default:600.0 "MASC_SENTINEL_BOARD_PATROL_SEC"
  let task_hygiene_interval_sec = get_float ~default:300.0 "MASC_SENTINEL_TASK_HYGIENE_SEC"
  let keeper_health_interval_sec = get_float ~default:300.0 "MASC_SENTINEL_KEEPER_HEALTH_SEC"
  let task_stuck_threshold_sec = get_float ~default:600.0 "MASC_SENTINEL_TASK_STUCK_SEC"
  let task_stale_threshold_sec = get_float ~default:1800.0 "MASC_SENTINEL_TASK_STALE_SEC"
  let llm_enabled = get_bool ~default:true "MASC_SENTINEL_LLM_ENABLED"
  let llm_timeout_sec = get_int ~default:30 "MASC_SENTINEL_LLM_TIMEOUT_SEC"
end

(** Print configuration summary for debugging *)
let print_summary () =
  Printf.eprintf "[env_config] Zombie: threshold=%.0fs cleanup_interval=%.0fs\n%!"
    Zombie.threshold_seconds Zombie.cleanup_interval_seconds;
  Printf.eprintf "[env_config] Lock: timeout=%.0fs expiry_warning=%.0fs\n%!"
    Lock.timeout_seconds Lock.expiry_warning_seconds;
  Printf.eprintf "[env_config] Session: max_age=%.0fs rate_limit_window=%.0fs\n%!"
    Session.max_age_seconds Session.rate_limit_window_seconds;
  Printf.eprintf "[env_config] Tempo: min=%.0fs max=%.0fs default=%.0fs\n%!"
    Tempo.min_interval_seconds Tempo.max_interval_seconds Tempo.default_interval_seconds;
  Printf.eprintf
    "[env_config] Llm: timeout=%.0fs cache_enabled=%b ttl=%ds max_prompt_chars=%d max_temp=%.2f l1_max=%d spawn_policy=%s\n%!"
    Llm.timeout_seconds Llm.cache_enabled Llm.cache_ttl_seconds
    Llm.cache_max_prompt_chars Llm.cache_max_temperature
    Llm.cache_l1_max_entries Llm.spawn_cache_policy;
  Printf.eprintf "[env_config] RateLimit: cleanup_interval=%.0fs entry_max_age=%.0fs\n%!"
    RateLimit.cleanup_interval_seconds RateLimit.entry_max_age_seconds;
  Printf.eprintf "[env_config] LodgeV2: tick=%.0fs agents_per_tick=%d planner=%b reflection_thresh=%d\n%!"
    LodgeV2.tick_interval_seconds LodgeV2.agents_per_tick
    LodgeV2.use_planner LodgeV2.reflection_threshold;
  Printf.eprintf "[env_config] LodgeSelection: max_starvation=%d thompson_weight=%.2f decay=%.2f\n%!"
    LodgeSelection.max_starvation_ticks LodgeSelection.thompson_weight
    LodgeSelection.vote_decay_factor;
  Printf.eprintf "[env_config] Gardener: enabled=%b min=%d target=%d max=%d spawns/day=%d\n%!"
    Gardener.enabled Gardener.min_agents Gardener.target_agents
    Gardener.max_agents Gardener.max_daily_spawns;
  Printf.eprintf "[env_config] KeeperBootstrap: enabled=%b stale_turn=%.0fs max_scan=%d\n%!"
    KeeperBootstrap.enabled KeeperBootstrap.stale_turn_seconds KeeperBootstrap.max_scan;
  Printf.eprintf "[env_config] KeeperAlert: enabled=%b min_score=%.2f retries=%d board=%b slack=%b github=%b\n%!"
    KeeperAlert.enabled KeeperAlert.min_score KeeperAlert.max_retries
    KeeperAlert.board_enabled KeeperAlert.slack_enabled KeeperAlert.github_enabled;
  Printf.eprintf "[env_config] KeeperAlert(SlackDM): enabled=%b user_id_set=%b\n%!"
    KeeperAlert.slack_dm_enabled (String.trim KeeperAlert.slack_dm_user_id <> "")
