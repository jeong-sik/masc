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

  (** Voice MCP HTTP request budget (seconds).

      Wraps two [run_voice_status] sites at [voice_bridge.ml:82,139]
      that drive the Voice MCP HTTP API (synthesis upload, file-form
      POST). Both shared the literal [35.0] — a single knob keeps
      uploaded-payload latency tunable fleet-wide for slow-network
      deployments. Floor 1.0s — anything smaller cannot accommodate
      even a localhost HTTP round trip with TLS handshake. *)
  let http_request_timeout_sec =
    Float.max 1.0
      (get_float ~default:35.0 "VOICE_HTTP_REQUEST_TIMEOUT_SEC")

  (** Audio test-tone subprocess budget (seconds).

      Wraps the [run_voice_status] call at [voice_bridge.ml:892] that
      spawns [sox play] for a 0.15s sine sweep. The 2.0s budget
      includes [sox] startup overhead; lowering this risks cutting
      off short tones on cold-start machines. Floor 0.2s prevents
      operators from disabling the tone via misconfiguration. *)
  let audio_test_tone_timeout_sec =
    Float.max 0.2
      (get_float ~default:2.0 "VOICE_AUDIO_TEST_TONE_TIMEOUT_SEC")
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

  (** Maximum time a task may remain AwaitingVerification before surfacing an
      operator-visible timeout. Default: 24h. *)
  let timeout_deadline_seconds () =
    get_float ~default:(24.0 *. 60.0 *. 60.0) "MASC_VERIFICATION_TIMEOUT_DEADLINE_SEC"

  (** Interval for verification timeout check fiber (seconds). Default: 60.
      Issue #7549. *)
  let timeout_check_interval_seconds =
    get_float ~default:60.0 "MASC_VERIFICATION_TIMEOUT_CHECK_INTERVAL_SEC"
end

(** {1 Goal Janitor}

    #10405: Goal_janitor.run was only invoked from the dashboard
    DELETE handler.  4 goals stagnated for 4 days with [last_review_at
    = null] and [goals_snapshots/] empty.  Add a periodic background
    fiber that sweeps stagnated goals on a 1-hour cadence by default. *)
module Goal_janitor = struct
  (** Enable the periodic goal_janitor sweep fiber.  Default: true.
      Set MASC_GOAL_JANITOR_ENABLED=false to disable when debugging. *)
  let enabled () =
    get_bool ~default:true "MASC_GOAL_JANITOR_ENABLED"

  (** Sweep interval in seconds.  Default: 3600 (1 hour).
      Goal stagnation is measured in days, so the cadence does not need
      to be tight; a coarse sweep keeps the fleet log uncluttered. *)
  let interval_seconds =
    get_float ~default:3600.0 "MASC_GOAL_JANITOR_INTERVAL_SEC"
end

(** {1 Approval Janitor}

    HITL approval queue dead-end fix.  [Keeper_approval_queue.expire_stale]
    has full implementation (queue removal, audit event, promise reject,
    on_resolution callback) and a unit test, but was never invoked
    anywhere in production code.  Result: any HITL approval enqueued
    by a keeper turn would block [keeper_cycle_decision] forever via
    [has_pending_for_keeper → Skip Approval_pending].  Once the 300s
    stale watchdog fired, the supervisor would respawn the fiber, the
    same approval would still be in the queue, and the cycle would
    repeat indefinitely.  This fork makes the existing timeout policy
    actually fire.  See #10765 for the death-spiral observability that
    surfaced this and #10962 for the [last_skip_observation]
    instrumentation that distinguishes deliberate-skip from stuck. *)
module Approval_janitor = struct
  (** Enable the periodic approval_janitor sweep fiber.  Default: true.
      Set MASC_APPROVAL_JANITOR_ENABLED=false to disable when
      debugging — pre-fix behaviour leaves the queue entries immortal
      until manual resolution or server restart. *)
  let enabled () =
    get_bool ~default:true "MASC_APPROVAL_JANITOR_ENABLED"

  (** Sweep interval in seconds.  Default: 60s (every minute).
      Operators tolerate up to a minute of "approval still pending"
      after the policy timeout has elapsed; a tighter cadence buys
      nothing but log churn.  Mirrors [Goal_janitor]'s exposure
      pattern (interval is operational cadence, not policy). *)
  let interval_seconds =
    get_float ~default:60.0 "MASC_APPROVAL_JANITOR_INTERVAL_SEC"
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

  (** Per-agent requests per second. Default: 20. *)
  let agent_rate = get_float ~default:20.0 "MASC_AGENT_RATE_LIMIT"

  (** Per-agent burst capacity. Default: 50. *)
  let agent_burst = get_int ~default:50 "MASC_AGENT_RATE_BURST"
end

(** {1 Per-Agent Rate Limit Bucket Configuration}

    A separate, lower-rate bucket applied per authenticated bearer token
    (i.e. per agent identity).  This limits how many requests a single
    agent can make regardless of how many different source IPs it uses,
    complementing the IP-level {!Rate_bucket} above.

    Configuration via environment:
    - MASC_AGENT_RATE_LIMIT: requests per second per agent (default: 30)
    - MASC_AGENT_RATE_BURST: burst capacity per agent (default: 60) *)

module Agent_rate_bucket = struct
  (** Requests per second per authenticated agent token. Default: 30. *)
  let rate = get_float ~default:30.0 "MASC_AGENT_RATE_LIMIT"

  (** Per-agent burst capacity. Default: 60. *)
  let burst = get_int ~default:60 "MASC_AGENT_RATE_BURST"
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

  (** Dashboard shell-cache pre-warm timeouts.

      The pre-warm fires once on server bootstrap. It is wrapped in two
      nested timeouts: the inner
      [Dashboard_cache.get_or_compute_with_timeout] budget covers the
      compute step only, while the outer [Eio.Time.with_timeout] also
      covers cache lookup, mutex contention and surrounding bookkeeping.
      The outer budget MUST strictly exceed the inner budget so the inner
      reports "compute timeout" rather than the fiber being killed by
      the outer wrapper. The default 30/35 split preserves the 5s
      headroom that the inline literals encoded.

      Previously hardcoded as inline literals at
      [server_dashboard_http_execution_surfaces.ml:7] (30.0) and
      [server_runtime_bootstrap.ml:1686] (35.0). On slow-disk or
      contended deployments the pre-warm dropped silently and the
      dashboard rendered cold — operators had no env to raise the
      ceiling without a rebuild ("기다려야 할 부분을 안 기다리는"
      pattern). *)
  let shell_prewarm_inner_timeout_sec =
    Float.max 1.0
      (get_float ~default:30.0 "MASC_DASHBOARD_SHELL_PREWARM_TIMEOUT_SEC")

  let shell_prewarm_outer_timeout_sec =
    Float.max 5.0
      (get_float ~default:35.0
         "MASC_DASHBOARD_SHELL_PREWARM_OUTER_TIMEOUT_SEC")

  (** Execution surface compute timeout (light + parameterized).

      Wraps two [Dashboard_cache.get_or_compute_with_timeout] sites at
      [server_dashboard_http_execution_surfaces.ml:437,449] (execution
      light/parameterized). Default 120s preserves the inline literals.
      Floor 5s ensures the budget can complete a typical projection
      hydration even under aggressive operator override. *)
  let execution_timeout_sec =
    Float.max 5.0
      (get_float ~default:120.0 "MASC_DASHBOARD_EXECUTION_TIMEOUT_SEC")

  (** Execution-trust surface compute timeout.

      Wraps [Dashboard_cache.get_or_compute_with_timeout] at
      [server_dashboard_http_execution_surfaces.ml:463] (execution-trust
      score). Default 30s preserves the inline literal. Smaller than
      [execution_timeout_sec] because the trust projection is
      intentionally lighter — keeping the split visible lets operators
      diagnose when trust scoring is the bottleneck vs. the full
      execution surface. *)
  let execution_trust_timeout_sec =
    Float.max 1.0
      (get_float ~default:30.0
         "MASC_DASHBOARD_EXECUTION_TRUST_TIMEOUT_SEC")

  (** Mission card compute timeout.

      Wraps three [Dashboard_cache.get_or_compute_with_timeout] sites at
      [server_dashboard_http_core.ml:624,633,678] (mission projections).
      Default 25s preserves the pre-extraction inline literal. Floor 1s
      protects against degenerate operator config. *)
  let mission_timeout_sec =
    Float.max 1.0
      (get_float ~default:25.0 "MASC_DASHBOARD_MISSION_TIMEOUT_SEC")

  (** Shell render compute timeout (full path).

      Used by [Dashboard_cache.get_or_compute_with_timeout] for the full
      shell render. Default 16s preserves the pre-extraction literal at
      [server_dashboard_http_core.ml:790]. *)
  let shell_timeout_sec =
    Float.max 1.0
      (get_float ~default:16.0 "MASC_DASHBOARD_SHELL_TIMEOUT_SEC")

  (** Shell render compute timeout (light path).

      Default 8s. Must remain strictly less than [shell_timeout_sec] so
      the split-budget signal (light vs full) stays meaningful: if a
      light render takes longer than the full budget, that means light
      has accidentally taken on full's work. Floor clamps at 0.5s to
      keep the comparison meaningful even under operator override. *)
  let shell_light_timeout_sec =
    Float.max 0.5
      (get_float ~default:8.0 "MASC_DASHBOARD_SHELL_LIGHT_TIMEOUT_SEC")

  (** Maximum wall-clock for a single dashboard render
      ([Dashboard_execution.json_render]).

      Wraps the entire render pipeline including PG stalls and cold-start
      projection hydration. Default 60s preserves the pre-extraction
      literal at [dashboard_execution.ml:204]. Floor 5s ensures even
      aggressive operator overrides leave room for cold-start hydration.
      Render budget should comfortably exceed the longest inner compute
      budget (currently [mission_timeout_sec] = 25s). *)
  let render_timeout_sec =
    Float.max 5.0
      (get_float ~default:60.0 "MASC_DASHBOARD_RENDER_TIMEOUT_SEC")
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

  (** Bootstrap janitor tick interval (seconds). Drives the SSE/session/
      rate-limit/webrtc reaper loop in [server_bootstrap_loops]. Default:
      60 (1 min). Shorter interval reclaims stale connections faster at
      the cost of more wake-ups; longer interval is fine if the process
      is sized for the steady-state connection count. *)
  let janitor_interval_sec =
    get_float ~default:60.0 "MASC_JANITOR_INTERVAL_SEC"

  (** Repository auto-sync interval (seconds). The repo_sync fiber in
      [server_bootstrap_loops] wakes at this cadence to fetch repositories
      with [auto_sync = true]. Default: 300 (5 min). *)
  let repo_sync_interval_sec =
    let value = get_float ~default:300.0 "MASC_REPO_SYNC_INTERVAL_SEC" in
    if value > 0.0 then value else 300.0

  (** Rate-limit bucket staleness TTL (seconds). Buckets with no traffic for
      this long are reaped by the janitor loop. Default: 300 (5 min). Raise
      for longer client quiet periods; lower to free memory faster under
      churn. [Rate_limit.cleanup] takes an int, so this is int-typed. *)
  let rate_limit_bucket_ttl_sec =
    get_int ~default:300 "MASC_RATE_LIMIT_BUCKET_TTL_SEC"
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

  (** Subprocess timeout (seconds) for sidecar control commands —
      [stop], [tail], and similar quick housekeeping operations.

      Wraps two [Process_eio.run_argv_with_status] sites at
      [server_routes_http_routes_sidecar.ml:780,835]. Default 5s
      preserves the inline literals; floor 1s prevents an operator
      typo from making every control command return "timeout" before
      the sidecar even handles the signal. *)
  let control_command_timeout_sec =
    Float.max 1.0
      (get_float ~default:5.0 "MASC_SIDECAR_CONTROL_TIMEOUT_SEC")

  (** Subprocess timeout (seconds) for sidecar Python schema
      generation. Wraps [Process_eio.run_argv_with_status] at
      [server_routes_http_routes_sidecar.ml:882]. Default 10s
      preserves the inline literal; this path runs Python interp +
      schema introspection so it needs more headroom than the
      lightweight control commands. Floor 1s.

      Must satisfy [schema_generation > control_command] — schema
      gen is strictly heavier than control commands, so an operator
      lowering schema budget below the control budget would silently
      reorder the implicit precedence and surprise downstream
      diagnostics. *)
  let schema_generation_timeout_sec =
    Float.max 1.0
      (get_float ~default:10.0 "MASC_SIDECAR_SCHEMA_TIMEOUT_SEC")
end

(** {1 Coord local git operation timeouts}

    Inline literals extracted from {!Coord_git} and
    {!Coord_worktree} (#10426 audit):

    - [coord_git.ml:45]        30.0  → run_argv_line  helper default
    - [coord_git.ml:74]        30.0  → run_argv_lines helper default
    - [coord_worktree.ml:21]   30.0  → run_argv_lines helper default
    - [coord_worktree.ml:868]  30.0  → direct [worktree add -B] call

    All four sites share the same semantic bucket: "local-only git
    operations" (rev-parse, status, branch, worktree add — no
    network IO).  Network-bound git ops (fetch, push) already use
    {!Env_config_core.git_fetch_timeout_sec}, which is the long
    counterpart and is intentionally a separate knob.

    The two budgets must remain separable: bundling local + network
    under one knob would force an operator who needs to extend a
    flaky [git fetch] over a slow proxy to also extend every
    [git rev-parse] subprocess on hot paths, padding tail latency
    needlessly.  Conversely, an operator narrowing local ops on a
    fast workstation would not expect to also narrow network ops. *)

module Coord_git = struct
  (** Budget (seconds) for local-only git operations under
      [Masc_exec.Exec_gate.run_argv*] in {!Coord_git} and
      {!Coord_worktree}: [rev-parse], [status], [branch],
      [worktree add], etc.

      Default 30.0 preserves the four inline literals.  Floor 5.0
      keeps the budget above subprocess startup + small index
      reads even on a busy system; misconfiguring lower than that
      would silently kill perfectly healthy commands.

      Network-bound ops (fetch, push) intentionally use a separate
      knob — see {!Env_config_core.git_fetch_timeout_sec}. *)
  let local_op_timeout_sec =
    Float.max 5.0
      (get_float ~default:30.0 "MASC_COORD_GIT_LOCAL_OP_TIMEOUT_SEC")
end

(** {1 Internal Safety Configuration} *)
