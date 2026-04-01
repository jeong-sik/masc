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
    get_bool ~default:false "MASC_ORCHESTRATOR_ENABLED"
end

(** {1 Relay Configuration} *)

module Relay = struct
  let target_agent =
    get_string ~default:"auto" "MASC_RELAY_TARGET_AGENT"
end

(** {1 MDAL Configuration} *)

module Mdal = struct
  let default_agent =
    get_string ~default:"auto" "MASC_MDAL_AGENT"
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
    get_string ~default:"http://127.0.0.1:8085" "LLAMA_SERVER_URL"

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

  (** Llama swarm model override (formerly in Chain module). *)
  let llama_swarm_model_opt () =
    Sys.getenv_opt "LLAMA_SWARM_MODEL" |> trim_opt

  (** MASC MCP endpoint URL (formerly in Chain module).
      Defaults to {base_url}/mcp. *)
  let mcp_url () =
    match Sys.getenv_opt "MASC_MCP_URL" |> trim_opt with
    | Some url -> url
    | None -> Env_config_core.masc_http_base_url () ^ "/mcp"
end

(** Backward-compatible alias so existing [Env_config.Llama] references
    continue to compile without changes. *)
module Llama = Local_runtime

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
    get_string ~default:"127.0.0.1" "VOICE_MCP_HOST"

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

(** {1 Transport Configuration} *)

module Transport = struct
  (** gRPC server port. Default: 8936. *)
  let grpc_port = get_port ~default:8936 "MASC_GRPC_PORT"

  (** Whether gRPC transport is enabled. Default: true.
      Runtime-readable (tests change this via putenv). *)
  let grpc_enabled () = get_bool ~default:true "MASC_GRPC_ENABLED"

  (** gRPC client target address. Derived from grpc_port when unset. *)
  let grpc_target_opt () =
    Sys.getenv_opt "MASC_GRPC_TARGET" |> trim_opt

  (** WebSocket server port. Default: 8937. *)
  let ws_port = get_port ~default:8937 "MASC_WS_PORT"

  (** Whether WebSocket transport is enabled. Default: true.
      Runtime-readable (tests change this via putenv). *)
  let ws_enabled () = get_bool ~default:true "MASC_WS_ENABLED"

  (** Whether WebRTC transport is enabled. Default: true.
      Runtime-readable (tests change this via putenv). *)
  let webrtc_enabled () = get_bool ~default:true "MASC_WEBRTC_ENABLED"

  (** HTTP mode: "auto", "h2_only", "h1_only". Default: "auto". *)
  let use_h2 () =
    match Sys.getenv_opt "MASC_USE_H2" |> trim_opt with
    | Some raw -> (
        match String.lowercase_ascii raw with
        | "1" | "true" -> "h2_only"
        | "0" | "false" -> "h1_only"
        | "auto" -> "auto"
        | other -> other)
    | None -> "auto"

  (** Agent transport type raw string (e.g. "grpc", "http", "ws"). *)
  let agent_transport_opt () =
    Sys.getenv_opt "MASC_AGENT_TRANSPORT" |> trim_opt

  (** Whether OpenAI-compatible endpoint is enabled. Default: false. *)
  let openai_compat_enabled = get_bool ~default:false "MASC_OPENAI_COMPAT"

  let _http_auth_strict_registry =
    get_bool ~default:false "MASC_HTTP_AUTH_STRICT"

  (** Force strict auth for all HTTP endpoints. Default: false. *)
  let http_auth_strict_env_enabled () =
    match Sys.getenv_opt "MASC_HTTP_AUTH_STRICT" |> trim_opt with
    | Some ("1" | "true" | "yes" | "y" | "on") -> true
    | _ -> false

  (** Startup watchdog timeout, clamped to [30, 600]. Default: 240.
      Runtime-readable (tests change this via putenv). *)
  let startup_watchdog_sec () =
    let v = get_float ~default:240.0 "MASC_STARTUP_WATCHDOG_SEC" in
    Float.max 30.0 (Float.min 600.0 v)
end

module TeamSession = struct
  let model_35b_opt () =
    Sys.getenv_opt "MASC_TEAM_SESSION_MODEL_35B" |> trim_opt

  let model_27b_opt () =
    Sys.getenv_opt "MASC_TEAM_SESSION_MODEL_27B" |> trim_opt

  let model_9b_opt () =
    Sys.getenv_opt "MASC_TEAM_SESSION_MODEL_9B" |> trim_opt

  (** Enable routing judge in team session dispatch. Default: true. *)
  let router_judge_enabled () =
    get_bool ~default:true "MASC_TEAM_SESSION_ROUTER_JUDGE"

  let router_judge_timeout_sec () =
    max 5 (get_int ~default:15 "MASC_TEAM_SESSION_ROUTER_JUDGE_TIMEOUT_SEC")

  let router_judge_confidence_threshold () =
    let value =
      get_float ~default:0.72 "MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD"
    in
    Float.max 0.0 (Float.min 1.0 value)

  let router_judge_model_opt () =
    Sys.getenv_opt "MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL" |> trim_opt
end

module Cdal = struct
  (** Enable contract-driven proof capture. Default: true. *)
  let enabled () =
    get_bool ~default:true "MASC_CDAL_ENABLED"

  (** Enforce contract risk violations. Default: false. *)
  let risk_enforcement_enabled () =
    get_bool ~default:false "MASC_CDAL_RISK_ENFORCEMENT"

  (** Aggregate proof bundles across turns. Default: false. *)
  let proof_aggregation_enabled () =
    get_bool ~default:false "MASC_CDAL_PROOF_AGGREGATION"
end

(** Release LLM slot during tool execution so other agents can use it.
    Default: false. Set MASC_SLOT_YIELD_ENABLED=true to enable. *)
let slot_yield_enabled () =
  get_bool ~default:false "MASC_SLOT_YIELD_ENABLED"

(** {1 Board Configuration} *)

module Board = struct
  (** Flush interval for board persistence (seconds). Default: 30. *)
  let flush_interval_sec =
    get_float ~default:30.0 "MASC_BOARD_FLUSH_INTERVAL_SEC"

  (** Board backend type (e.g. "jsonl", "pg"). *)
  let backend_opt () =
    Sys.getenv_opt "MASC_BOARD_BACKEND" |> trim_opt
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
  let dispatch_v2_enabled = get_bool ~default:true "MASC_DISPATCH_V2"

  (** Full tool surface override. Default: false.
      Runtime-readable (tests change this via putenv). *)
  let full_surface_enabled () = get_bool ~default:false "MASC_FULL_SURFACE"

  (** Tool list page size, clamped to [10, 1024]. Default: 512.
      Runtime-readable (tests change this via putenv). *)
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
  (** Enable local runtime debug logging. Default: false.
      Falls back to MASC_LLAMA_RUNTIME_DEBUG for backward compatibility. *)
  let local_runtime_debug =
    let primary = get_bool ~default:false "MASC_LOCAL_RUNTIME_DEBUG" in
    if primary then true
    else get_bool ~default:false "MASC_LLAMA_RUNTIME_DEBUG"

  (** @deprecated Use {!local_runtime_debug}. *)
  let llama_runtime_debug = local_runtime_debug

  (** Local runtime cooldown (seconds).
      Falls back to MASC_LLAMA_RUNTIME_COOLDOWN_SEC for backward compatibility. *)
  let local_runtime_cooldown_sec_opt () =
    match Sys.getenv_opt "MASC_LOCAL_RUNTIME_COOLDOWN_SEC" |> trim_opt with
    | Some _ as v -> v
    | None -> Sys.getenv_opt "MASC_LLAMA_RUNTIME_COOLDOWN_SEC" |> trim_opt

  (** @deprecated Use {!local_runtime_cooldown_sec_opt}. *)
  let llama_runtime_cooldown_sec_opt = local_runtime_cooldown_sec_opt

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

(** {1 Internal Safety Configuration} *)
