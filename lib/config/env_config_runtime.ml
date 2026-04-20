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

  let min_priority =
    max 0 (min 10 (get_int ~default:2 "MASC_ORCHESTRATOR_MIN_PRIORITY"))

  let timeout_seconds =
    max 10 (min 3600 (get_int ~default:300 "MASC_ORCHESTRATOR_TIMEOUT"))

  let enabled =
    Feature_flag_registry.get_bool Env_config_core.orchestrator_enabled_env_key
end

(** {1 Relay Configuration} *)

module Relay = struct
  let target_agent =
    get_string ~default:"auto" "MASC_RELAY_TARGET_AGENT"
end

(** {1 CLI Configuration} *)

module Cli = struct
  let default_agent =
    get_string ~default:"auto" "MASC_CLI_AGENT"
end

(** {1 Spawn Configuration} *)

module Spawn = struct
  (** Default spawn timeout for agent processes (seconds).
      Used by spawn.ml, spawn_eio.ml, and tool_relay.ml.
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
    get_string ~default:Masc_network_defaults.local_llm_default_url "LLAMA_SERVER_URL"

  (** Default local runtime model id for llama.cpp/OpenAI-compatible servers. *)
  let default_model =
    get_string ~default:"explicit-model-required" "LLAMA_DEFAULT_MODEL"

  (** Upper bound for local runtime requests.
      Callers may request less, but never more than this cap.
      Falls back to MASC_LLAMA_MAX_TOKENS for backward compatibility. *)
  let max_tokens =
    let primary = get_int ~default:0 "MASC_LOCAL_MAX_TOKENS" in
    if primary > 0 then primary
    else get_int ~default:32768 "MASC_LLAMA_MAX_TOKENS"

  (** Default worker model override for the local runtime. *)
  let worker_model_opt () =
    Sys.getenv_opt "LLAMA_WORKER_MODEL" |> trim_opt

  (** Env var that overrides the default MCP endpoint URL. Exposed as
      SSOT so out-of-process callers (e.g. [worker_runtime_docker.ml]
      that need container-local URL rewriting) read the same literal
      without re-inlining the string. Issue #8352. *)
  let mcp_url_env_key = "MASC_MCP_URL"

  (** MASC MCP endpoint URL (formerly in Chain module).
      Defaults to {base_url}/mcp. *)
  let mcp_url () =
    match Sys.getenv_opt mcp_url_env_key |> trim_opt with
    | Some url -> url
    | None -> Env_config_core.masc_http_base_url () ^ "/mcp"
end

(** Backward-compatible alias so existing [Env_config.Llama] references
    continue to compile without changes. *)
module Llama = Local_runtime

module Ollama = struct
  let server_url =
    get_string ~default:Masc_network_defaults.ollama_default_url "OLLAMA_SERVER_URL"

  let default_model =
    get_string ~default:"" "OLLAMA_DEFAULT_MODEL"
end

module Glm = struct
  let server_url = Env_config_core.get_string ~default:"https://api.z.ai" "ZAI_BASE_URL"
end

(** {1 Cancellation Token Configuration} *)

module Cancellation = struct
  (** Token cleanup max age (seconds) *)
  let token_max_age_seconds =
    get_float ~default:3600.0 "MASC_CANCELLATION_TOKEN_MAX_AGE_SEC"
end

(** {1 Voice Bridge Configuration} *)

module Voice = struct
  (** Default Voice MCP server host *)
  let default_host =
    get_string ~default:Masc_network_defaults.masc_http_default_host
      "VOICE_MCP_HOST"

  (** Default Voice MCP server port *)
  let default_port =
    get_int ~default:8936 "VOICE_MCP_PORT"
end

(** {1 Timeout Defaults} *)

module Timeout = struct
  (** gcloud auth token fetch (used by a2a_tools, model_client, keeper_alerting) *)
  let gcloud_auth_sec =
    get_float ~default:15.0 "MASC_TIMEOUT_GCLOUD_AUTH_SEC"
end

(** {1 Message GC Configuration} *)

module Message = struct
  (** Maximum number of message files to retain per room (default 200).
      Oldest messages (by filename sort) are deleted when count exceeds this. *)
  let max_count =
    get_int ~default:200 "MASC_MESSAGE_MAX_COUNT"
end

(** {1 Transport Configuration} *)

module Transport = struct
  type h2_mode =
    | Auto
    | H1_only
    | H2_only
    | Unknown_h2_mode of string

  let normalize_token raw =
    raw |> String.trim |> String.lowercase_ascii

  let h2_mode_of_string raw =
    match normalize_token raw with
    | "1" | "true" | "h2_only" -> H2_only
    | "0" | "false" | "h1_only" -> H1_only
    | "auto" -> Auto
    | other -> Unknown_h2_mode other

  let h2_mode_to_string = function
    | Auto -> "auto"
    | H1_only -> "h1_only"
    | H2_only -> "h2_only"
    | Unknown_h2_mode value -> value

  type agent_transport =
    | Http
    | Grpc
    | Ws
    | Webrtc
    | Local
    | Unknown_agent_transport of string

  let agent_transport_of_string raw =
    match normalize_token raw with
    | "http" -> Http
    | "grpc" -> Grpc
    | "ws" | "websocket" -> Ws
    | "webrtc" -> Webrtc
    | "local" -> Local
    | other -> Unknown_agent_transport other

  let agent_transport_to_string = function
    | Http -> "http"
    | Grpc -> "grpc"
    | Ws -> "ws"
    | Webrtc -> "webrtc"
    | Local -> "local"
    | Unknown_agent_transport value -> value

  (** gRPC server port. Default: 8936. *)
  let grpc_port = get_port ~default:8936 "MASC_GRPC_PORT"

  (** Whether gRPC transport is enabled. Default: true.
      Accessor-shaped reader; listener lifecycle is still decided at boot. *)
  let grpc_enabled () = Feature_flag_registry.get_bool "MASC_GRPC_ENABLED"

  (** gRPC client target address. Derived from grpc_port when unset. *)
  let grpc_target_opt () =
    Sys.getenv_opt "MASC_GRPC_TARGET" |> trim_opt

  (** WebSocket server port. Default: 8937. *)
  let ws_port = get_port ~default:8937 "MASC_WS_PORT"

  (** Whether WebSocket transport is enabled. Default: true.
      Accessor-shaped reader; listener lifecycle is still decided at boot. *)
  let ws_enabled () = Feature_flag_registry.get_bool "MASC_WS_ENABLED"

  (** Whether WebRTC transport is enabled. Default: true.
      Accessor-shaped reader; listener lifecycle is still decided at boot. *)
  let webrtc_enabled () = Feature_flag_registry.get_bool "MASC_WEBRTC_ENABLED"

  (** HTTP mode: typed variant for "auto", "h2_only", "h1_only". *)
  let use_h2 () =
    match Sys.getenv_opt "MASC_USE_H2" |> trim_opt with
    | Some raw -> h2_mode_of_string raw
    | None -> Auto

  (** Agent transport type variant (e.g. "grpc", "http", "ws"). *)
  let agent_transport_opt () =
    Sys.getenv_opt "MASC_AGENT_TRANSPORT"
    |> trim_opt
    |> Option.map agent_transport_of_string

  (** Whether OpenAI-compatible endpoint is enabled. Default: false. *)
  let openai_compat_enabled = Feature_flag_registry.get_bool "MASC_OPENAI_COMPAT"

  let _http_auth_strict_registry =
    Feature_flag_registry.get_bool "MASC_HTTP_AUTH_STRICT"

  (** Force strict auth for all HTTP endpoints. Default: false. *)
  let http_auth_strict_env_enabled () =
    match Sys.getenv_opt "MASC_HTTP_AUTH_STRICT" |> trim_opt with
    | Some ("1" | "true" | "yes" | "y" | "on") -> true
    | _ -> false

  (** Startup watchdog timeout, clamped to [30, 600]. Default: 240.
      Re-readable within the process, but operationally a boot-time input. *)
  let startup_watchdog_sec () =
    let v = get_float ~default:240.0 "MASC_STARTUP_WATCHDOG_SEC" in
    Float.max 30.0 (Float.min 600.0 v)
end

module Cdal = struct
  (** Enable contract-driven proof capture. Default: true. *)
  let enabled () =
    Feature_flag_registry.get_bool "MASC_CDAL_ENABLED"

  (** Block task completion when CDAL verdict is Violated/Inconclusive. Default: false. *)
  let gate_enabled () =
    Feature_flag_registry.get_bool "MASC_CDAL_GATE_ENABLED"

  (** Max verdicts to scan when looking up the latest verdict by task_id.
      Beyond this limit, older entries are silently skipped — WARN is logged
      by the gate when the task_id is not found. Default: 500.
      Issue #7546. *)
  let verdict_lookup_limit () =
    get_int ~default:500 "MASC_CDAL_VERDICT_LOOKUP_LIMIT"
end

module Verification = struct
  (** Enable AwaitingVerification state and cross-agent approval. Default: false. *)
  let fsm_enabled () =
    Feature_flag_registry.get_bool "MASC_VERIFICATION_FSM_ENABLED"

  (** Interval for verification timeout check fiber (seconds). Default: 60.
      Issue #7549. *)
  let timeout_check_interval_seconds =
    get_float ~default:60.0 "MASC_VERIFICATION_TIMEOUT_CHECK_INTERVAL_SEC"
end

(** {1 Slot Scheduling} *)

module Slot = struct
  (** Release LLM slot during tool execution so other agents can use it.
      Default: false. Set MASC_SLOT_YIELD_ENABLED=true to enable. *)
  let yield_enabled () =
    Feature_flag_registry.get_bool "MASC_SLOT_YIELD_ENABLED"
end

(** {1 Board Configuration} *)

module Board = struct
  type backend =
    | Jsonl
    | Pg
    | Unknown_backend of string

  let backend_of_string raw =
    match raw |> String.trim |> String.lowercase_ascii with
    | "jsonl" -> Jsonl
    | "pg" -> Pg
    | other -> Unknown_backend other

  let backend_to_string = function
    | Jsonl -> "jsonl"
    | Pg -> "pg"
    | Unknown_backend value -> value

  (** Flush interval for board persistence (seconds). Default: 30. *)
  let flush_interval_sec =
    get_float ~default:30.0 "MASC_BOARD_FLUSH_INTERVAL_SEC"

  (** Board backend type as a typed selector (e.g. "jsonl", "pg"). *)
  let backend_opt () =
    Sys.getenv_opt "MASC_BOARD_BACKEND"
    |> trim_opt
    |> Option.map backend_of_string
end

(** {1 Procedural Memory Configuration} *)

module ProcMemory = struct
  (** Minimum evidence count for crystallization. Default: 3. *)
  let min_evidence = max 1 (get_int ~default:3 "MASC_PROC_MIN_EVIDENCE")

  (** Minimum confidence for crystallization, clamped to [0, 1]. Default: 0.7. *)
  let min_confidence =
    Float.max 0.0 (Float.min 1.0 (get_float ~default:0.7 "MASC_PROC_MIN_CONFIDENCE"))
end

(** {1 Pulse Configuration} *)

module Pulse_config = struct
  (** Max consecutive consumer failures before recovery. Default: 3. *)
  let max_consumer_failures = max 1 (get_int ~default:3 "MASC_PULSE_MAX_CONSUMER_FAILURES")
end

(** {1 Tool Surface Configuration} *)

module Tools = struct
  (** Dispatch v2 feature flag. Default: true (since v2.102). *)
  let dispatch_v2_enabled = Feature_flag_registry.get_bool "MASC_DISPATCH_V2"

  (** Full tool surface override. Default: false.
      Re-readable within the process; callers should still document the
      effective reload contract at the subsystem boundary. *)
  let full_surface_enabled () = Feature_flag_registry.get_bool "MASC_FULL_SURFACE"

  (** Tool list page size, clamped to [10, 1024]. Default: 512.
      Re-readable within the process; not a guarantee of shell-level hot reload. *)
  let list_page_size () =
    let v = get_int ~default:512 "MASC_LIST_PAGE_SIZE" in
    max 10 (min 1024 v)

  (** Tool description budget (max chars). None = unlimited. *)
  let description_budget_opt () =
    match Sys.getenv_opt "MASC_TOOL_DESCRIPTION_BUDGET" |> trim_opt with
    | Some raw -> (
        match int_of_string_opt raw with
        | Some v when v > 0 -> Some v
        | _ -> None)
    | None -> None

  (** Read-only tool retry limit. Default: 2. *)
  let readonly_retry_limit = get_int ~default:2 "MASC_TOOL_READONLY_RETRY_LIMIT"

  (** Extra public tools (comma-separated names). *)
  let public_tools_extra_opt () =
    Sys.getenv_opt "MASC_PUBLIC_TOOLS_EXTRA" |> trim_opt

  let web_search_provider_opt () =
    Sys.getenv_opt "MASC_WEB_SEARCH_PROVIDER" |> trim_opt

  let web_search_provider_order_opt () =
    Sys.getenv_opt "MASC_WEB_SEARCH_PROVIDER_ORDER" |> trim_opt

  let web_search_fallbacks_opt () =
    Sys.getenv_opt "MASC_WEB_SEARCH_FALLBACKS" |> trim_opt

  let web_search_timeout_sec () =
    let v = get_int ~default:15 "MASC_WEB_SEARCH_TIMEOUT_SEC" in
    max 1 (min 60 v)

  let web_search_cache_ttl_sec () =
    let v = get_float ~default:30.0 "MASC_WEB_SEARCH_CACHE_TTL_SEC" in
    if v < 0.0 then 0.0 else v

  let web_search_rate_limit_window_sec () =
    let v = get_float ~default:30.0 "MASC_WEB_SEARCH_RATE_LIMIT_WINDOW_SEC" in
    if v < 1.0 then 1.0 else v

  let web_search_rate_limit_max_calls () =
    let v = get_int ~default:30 "MASC_WEB_SEARCH_RATE_LIMIT_MAX_CALLS" in
    max 1 v
end

(** {1 Rate Limit Bucket Configuration} *)

module Rate_bucket = struct
  (** Requests per second. Default: 100. *)
  let rate = get_float ~default:100.0 "MASC_RATE_LIMIT"

  (** Burst capacity. Default: 150. *)
  let burst = get_int ~default:150 "MASC_RATE_BURST"
end

(** {1 Worker / Local Runtime Configuration} *)

module Worker = struct
  (** Enable local runtime debug logging. Default: false. *)
  let local_runtime_debug =
    Feature_flag_registry.get_bool "MASC_LOCAL_RUNTIME_DEBUG"

  (** Local runtime cooldown (seconds). *)
  let local_runtime_cooldown_sec_opt () =
    Sys.getenv_opt "MASC_LOCAL_RUNTIME_COOLDOWN_SEC" |> trim_opt

  (** Local worker max tokens per request. Default: 1024. *)
  let local_worker_max_tokens = max 1 (get_int ~default:1024 "MASC_LOCAL_WORKER_MAX_TOKENS")

  (** Local worker heartbeat interval (seconds). Default: 60. *)
  let local_worker_heartbeat_sec = max 1 (get_int ~default:60 "MASC_LOCAL_WORKER_HEARTBEAT_SEC")
end

(** {1 OAS SSE Bridge Configuration} *)

module Oas_sse = struct
  (** SSE drain interval (seconds). Default: 2.0. *)
  let drain_interval_sec =
    let v = get_float ~default:2.0 "MASC_OAS_SSE_DRAIN_INTERVAL_SEC" in
    if v < 0.1 then 2.0 else v
end

(** {1 Memory OAS Bridge Configuration} *)

module Memory_oas = struct
  (** Default importance for OAS-stored memories, clamped to [1, 10]. Default: 5. *)
  let default_importance = max 1 (min 10 (get_int ~default:5 "MASC_MEMORY_OAS_DEFAULT_IMPORTANCE"))
end

(** {1 Smart Heartbeat Tuning} *)

module SmartHeartbeatTuning = struct
  (** Base heartbeat interval (seconds), clamped [5, 300]. Default: 30. *)
  let base_interval_s =
    let v = get_float ~default:30.0 "MASC_SMART_HB_BASE_INTERVAL_SEC" in
    Float.max 5.0 (Float.min 300.0 v)

  (** Idle multiplier for interval, clamped [1, 10]. Default: 3. *)
  let idle_multiplier =
    let v = get_float ~default:3.0 "MASC_SMART_HB_IDLE_MULTIPLIER" in
    Float.max 1.0 (Float.min 10.0 v)

  (** Idle threshold (seconds) before multiplier kicks in, clamped [60, 3600]. Default: 300. *)
  let idle_threshold_s =
    let v = get_float ~default:300.0 "MASC_SMART_HB_IDLE_THRESHOLD_SEC" in
    Float.max 60.0 (Float.min 3600.0 v)
end

(** {1 Dashboard Signal Thresholds} *)

module Dashboard = struct
  (** Signal-age guardrail thresholds (seconds).
      Configurable via environment for runtime tuning without recompilation. *)

  (** Duration (seconds) after which a signal is considered stale. Default: 1200 (20 min). *)
  let signal_stale_sec =
    get_float ~default:1200.0 "MASC_DASHBOARD_SIGNAL_STALE_SEC"

  (** Duration (seconds) for borderline "quiet" warning. Default: 600 (10 min). *)
  let signal_quiet_sec =
    get_float ~default:600.0 "MASC_DASHBOARD_SIGNAL_QUIET_SEC"

  (** Duration (seconds) for a signal to count as "live". Default: 300 (5 min). *)
  let signal_live_sec =
    get_float ~default:300.0 "MASC_DASHBOARD_SIGNAL_LIVE_SEC"

  (** Keeper action-age threshold (seconds). Default: 3600 (1 hour). *)
  let keeper_action_stale_sec =
    get_float ~default:3600.0 "MASC_DASHBOARD_KEEPER_ACTION_STALE_SEC"

  (** Keeper context-ratio lifecycle thresholds.
      Higher ratio = closer to context limit = more urgency. *)
  let ctx_handoff_imminent =
    get_float ~default:0.85 "MASC_DASHBOARD_CTX_HANDOFF_IMMINENT"
  let ctx_preparing =
    get_float ~default:0.70 "MASC_DASHBOARD_CTX_PREPARING"
  let ctx_compacting =
    get_float ~default:0.50 "MASC_DASHBOARD_CTX_COMPACTING"
end

(** {1 Internal Timers and TTLs}

    Internal cache/GC/flush intervals. Low operational impact but
    centralized here to eliminate scattered magic 300.0/3600.0 literals. *)

module InternalTimers = struct
  (** Tool metrics flush interval (seconds). Default: 300 (5 min). *)
  let metrics_flush_sec =
    get_float ~default:300.0 "MASC_METRICS_FLUSH_SEC"

  (** Team session live turn window (seconds). Default: 300 (5 min). *)
  let session_live_turn_window_sec =
    get_float ~default:300.0 "MASC_SESSION_LIVE_TURN_WINDOW_SEC"

  (** Dashboard label "quiet" threshold (seconds). Default: 300 (5 min). *)
  let label_quiet_threshold_sec =
    get_float ~default:300.0 "MASC_LABEL_QUIET_THRESHOLD_SEC"

  (** Dashboard label "stuck" threshold (seconds). Default: 900 (15 min). *)
  let label_stuck_threshold_sec =
    get_float ~default:900.0 "MASC_LABEL_STUCK_THRESHOLD_SEC"

  (** Dashboard mission briefing cache TTL (seconds). Default: 300 (5 min). *)
  let briefing_cache_ttl_sec =
    get_float ~default:300.0 "MASC_BRIEFING_CACHE_TTL_SEC"

  (** Keeper world observation bootstrap window (seconds). Default: 300 (5 min). *)
  let bootstrap_window_sec =
    get_float ~default:300.0 "MASC_KEEPER_BOOTSTRAP_WINDOW_SEC"

  (** SSE buffer TTL (seconds). Default: 300 (5 min). *)
  let sse_buffer_ttl_sec =
    get_float ~default:300.0 "MASC_SSE_BUFFER_TTL_SEC"

  (** Cancellation token cleanup interval (seconds). Default: 300 (5 min). *)
  let cancellation_cleanup_sec =
    get_float ~default:300.0 "MASC_CANCELLATION_CLEANUP_SEC"

  (** Provider run finished TTL (seconds). Default: 3600 (1 hour). *)
  let provider_run_ttl_sec =
    get_float ~default:3600.0 "MASC_PROVIDER_RUN_TTL_SEC"

  (** Operator digest stalled session threshold (seconds). Default: 300 (5 min). *)
  let stalled_session_threshold_sec =
    get_float ~default:300.0 "MASC_STALLED_SESSION_THRESHOLD_SEC"
end

(** {1 Sidecar reconcile loop}

    Retry/backoff knobs for the connector sidecar lifecycle (#8919). Operator
    override lets us tune backoff without recompilation when a sidecar is
    flapping vs. genuinely offline. See #8930 for the SSOT consolidation. *)

module Sidecar = struct
  (** Backoff window (seconds) between repeated same-generation
      [running + unavailable] start dispatches. Default: 30 (matches the
      inline literal that landed in #8919). *)
  let reconcile_backoff_sec =
    get_float ~default:30.0 "MASC_SIDECAR_RECONCILE_BACKOFF_SEC"
end

(** {1 Internal Safety Configuration} *)
