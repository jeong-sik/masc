open Env_config_core

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

(** {1 Decision Configuration} *)

module Decision = struct
  (** Default TTL for pending decisions (seconds, default 1 hour) *)
  let ttl_seconds =
    get_float ~default:3600.0 "MASC_DECISION_TTL_SEC"
end

(** {1 Cache Configuration} *)

module Cache = struct
  (** Maximum size of a single cache entry value in bytes (default 100KB) *)
  let max_entry_size =
    get_int ~default:102400 "MASC_CACHE_MAX_ENTRY_SIZE"

  (** Maximum total number of cache entries (default 1000) *)
  let max_entries =
    get_int ~default:1000 "MASC_CACHE_MAX_ENTRIES"
end

(** {1 Task Claim Configuration} *)

module Claim = struct
  (** Maximum time a task can stay Claimed/InProgress without agent heartbeat
      before being auto-released back to Todo (seconds, default 1 hour). *)
  let ttl_seconds =
    get_float ~default:3600.0 "MASC_CLAIM_TTL_SECONDS"
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

  (** Extended timeout for coding mode (seconds). Default 2 hours. *)
  let coding_timeout_seconds =
    int_of_float (get_float ~default:7200.0 "MASC_SPAWN_CODING_TIMEOUT_SEC")

  (** Grace period before timeout — sends SIGTERM for checkpoint opportunity (seconds). *)
  let grace_period_seconds =
    int_of_float (get_float ~default:60.0 "MASC_SPAWN_GRACE_PERIOD_SEC")
end

(** {1 Local MODEL Server Configuration} *)

(** Local MODEL runtime config (llama-server / any OpenAI-compatible backend).
    Environment variables retain the LLAMA_ prefix for backward compatibility. *)
module Local_runtime = struct
  (** OpenAI-compatible local MODEL server URL *)
  let server_url =
    get_string ~default:"http://127.0.0.1:8085" "LLAMA_SERVER_URL"

  (** Default local runtime model id for llama.cpp/OpenAI-compatible servers. *)
  let default_model =
    get_string ~default:"explicit-model-required" "LLAMA_DEFAULT_MODEL"

  (** Upper bound for local llama-provider requests.
      Callers may request less, but never more than this cap. *)
  let max_tokens =
    get_int ~default:32768 "MASC_LLAMA_MAX_TOKENS"
end

(** Backward-compatible alias so existing [Env_config.Llama] references
    continue to compile without changes. *)
module Llama = Local_runtime

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

(** {1 Neo4j Configuration} *)

module Neo4j = struct
  (** Bolt connection URI *)
  let uri =
    get_string ~default:"bolt://turntable.proxy.rlwy.net:11490" "NEO4J_URI"

  (** HTTP API URI (overrides bolt-to-HTTP conversion when set) *)
  let http_uri =
    get_string ~default:"" "NEO4J_HTTP_URI"

  (** Database user *)
  let user =
    get_string ~default:"neo4j" "NEO4J_USER"

  (** Require NEO4J_PASSWORD from environment. Returns Error if unset or empty. *)
  let password_result () : (string, string) result =
    match Sys.getenv_opt "NEO4J_PASSWORD" with
    | Some pw when String.trim pw <> "" -> Ok pw
    | Some _ -> Error "NEO4J_PASSWORD is set but empty"
    | None -> Error "NEO4J_PASSWORD not set"
end

(** {1 Voice Bridge Configuration} *)

module Voice = struct
  (** Default Voice MCP server host *)
  let default_host =
    get_string ~default:"127.0.0.1" "VOICE_MCP_HOST"

  (** Default Voice MCP server port *)
  let default_port =
    get_int ~default:8936 "VOICE_MCP_PORT"
end

(** {1 MODEL Provider Defaults} *)

module Custom_model = struct
  (** Default URL for custom OpenAI-compatible server *)
  let default_server_url =
    get_string ~default:"http://127.0.0.1:8080" "CUSTOM_MODEL_SERVER_URL"
end

(** {1 Network Utilities} *)

module Network = struct
  (** Check if a host string refers to the local machine.
      Covers localhost, 127.0.0.0/8 (any 127.x address), and ::1. *)
  let is_localhost host =
    host = "localhost"
    || host = "::1"
    || String.length host >= 4 && String.sub host 0 4 = "127."
end

(** {1 Timeout Defaults} *)

module Timeout = struct
  (** gcloud auth token fetch (used by a2a_tools, model_client, keeper_alerting) *)
  let gcloud_auth_sec =
    get_float ~default:15.0 "MASC_TIMEOUT_GCLOUD_AUTH_SEC"

  (** Anthropic / Claude API request timeout *)
  let anthropic_api_sec =
    get_int ~default:120 "MASC_TIMEOUT_ANTHROPIC_SEC"

  (** OpenAI-compatible API request timeout *)
  let openai_compat_api_sec =
    get_int ~default:60 "MASC_TIMEOUT_OPENAI_COMPAT_SEC"

  (** Grace period added on top of MODEL timeouts for curl/network overhead *)
  let model_grace_sec =
    get_float ~default:5.0 "MASC_TIMEOUT_MODEL_GRACE_SEC"

  (** GraphQL query timeout (agent loading, etc.) *)
  let graphql_query_sec =
    get_float ~default:5.0 "MASC_TIMEOUT_GRAPHQL_SEC"

  (** Keeper status check timeout *)
  let keeper_status_sec =
    get_float ~default:5.0 "MASC_TIMEOUT_KEEPER_STATUS_SEC"
end

(** {1 MODEL Generation Defaults} *)

module Inference_defaults = struct
  (** Default max_tokens for MODEL generation (used by spawn, chain, perpetual, etc.) *)
  let default_max_tokens =
    get_int ~default:4096 "MASC_INFERENCE_DEFAULT_MAX_TOKENS"

  (** SSE retry interval in milliseconds (client reconnection hint) *)
  let sse_retry_ms =
    get_int ~default:3000 "MASC_SSE_RETRY_MS"

  (** Log output truncation length *)
  let log_truncation_len =
    get_int ~default:1500 "MASC_LOG_TRUNCATION_LEN"
end

(** {1 Control Plane Cleanup Configuration} *)

module Cp = struct
  (** Number of days before dead/stale CP data is eligible for cleanup (default 14) *)
  let cleanup_days =
    get_int ~default:14 "MASC_CP_CLEANUP_DAYS"
end

(** {1 Message GC Configuration} *)

module Message = struct
  (** Maximum number of message files to retain per room (default 200).
      Oldest messages (by filename sort) are deleted when count exceeds this. *)
  let max_count =
    get_int ~default:200 "MASC_MESSAGE_MAX_COUNT"
end

(** {1 Chain Executor Configuration} *)

module Chain = struct
  (** Model used for evaluator/judge calls in chain execution.
      Applies to MCTS scoring, anti-fake detection, goal metric evaluation,
      and feedback loop quality assessment. *)
  let judge_model =
    get_string ~default:"gemini" "MASC_CHAIN_JUDGE_MODEL"
end

(** {1 Internal Safety Configuration} *)
