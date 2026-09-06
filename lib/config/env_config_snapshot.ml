(** Env_config_snapshot — shared config introspection categories and JSON envelope.

    This module lives in the [masc_config] sub-library so both [Env_config]
    and root-level wrappers such as [Env_config_introspect] can reuse the same
    category definitions, masking rules, and source attribution logic. *)

let entry = Env_config_snapshot_collector.entry
let category = Env_config_snapshot_collector.category

let keeper_registry_entries predicate =
  Keeper_runtime_setting_registry.all
  |> List.filter predicate
  |> List.map (fun (row : Keeper_runtime_setting_registry.setting) ->
    entry ~default:row.default_display row.env_name row.description)
;;

let keeper_runtime_entries =
  keeper_registry_entries (fun row ->
    String.starts_with ~prefix:"MASC_KEEPER_" row.env_name)
;;

let keeper_web_search_entries =
  keeper_registry_entries (fun row -> String.equal row.category "web_search")
;;

let server_entries =
  [
    entry ~default:Masc_network_defaults.masc_http_default_port_s Env_config_core.http_port_env_key "HTTP server port";
    entry ~default:Env_config_core.default_host Env_config_core.host_env_key "Server bind host";
    entry ~default:"(derived)" Env_config_core.http_base_url_env_key "Public HTTP base URL";
    entry ~default:"(derived)" Env_config_core.mcp_url_env_key
      "MASC MCP endpoint URL (derived from base URL when unset)";
    entry ~default:"" "MASC_CLUSTER_NAME" "Cluster name for multi-instance";
    entry ~default:"(cwd)" Env_config_core.base_path_env_key "Base storage directory";
    entry ~default:Masc_network_defaults.masc_http_default_host
      "MASC_HTTP_HOST" "HTTP server listen host";
    entry ~default:Masc_network_defaults.masc_http_default_max_connections_s
      "MASC_HTTP_MAX_CONNECTIONS" "HTTP server max connections";
  ]

(* Rows from {!Env_setting} declarations. A knob declared there is reported
   without being restated here, which is the shape the hand-written lists below
   are being moved to. *)
let declared_entries category =
  Env_setting.rows_in ~category
  |> List.map (fun (row : Env_setting.row) ->
    entry ~default:row.default_display row.env_name row.description)
;;

let auth_entries =
  [
    entry ~sensitive:true ~default:"(none)" Env_config_core.admin_token_env_key
      "Admin authentication token";
    entry ~default:"false" "MASC_ALLOW_ANONYMOUS_MUTATIONS"
      "Allow anonymous mutations (local dev only)";
    entry ~default:"false" "MASC_HTTP_AUTH_STRICT"
      "Require auth for HTTP endpoints";
  ]
  @ declared_entries "auth"

let runtime_entries =
  [
    entry ~default:"(auto)" Env_config_core.log_level_env_key "Log level override";
    entry ~default:"debug" Env_config_core.log_routine_level_env_key
      "Routine telemetry log level override (debug|info|warn|error|off)";
    entry ~default:"false" Env_config_core.parse_warn_env_key
      "Escalate malformed env parses to Config_error";
    entry ~default:"true" Env_config_core.telemetry_enabled_env_key
      "Enable telemetry collection";
    entry ~default:"30" "MASC_TELEMETRY_RETENTION_DAYS"
      "Telemetry JSONL day-file retention days. Positive values override; \
       non-positive disables retention.";
    entry ~default:"52428800" "MASC_TELEMETRY_MAX_BYTES"
      "Telemetry JSONL byte cap. Positive values override; non-positive \
       disables byte-cap pruning.";
    entry ~default:"60.0" "MASC_MAINTENANCE_PULSE_INTERVAL_SEC"
      "Maintenance Pulse interval for orphan observation and channel dedup";
    entry ~default:"15.0" "MASC_SCHEDULE_RUNNER_INTERVAL_SEC"
      "Schedule runner due-row poll interval (seconds, floor 1.0); \
       stale_after is derived as interval x4";
  ]

let rate_limiting_entries =
  [
    entry ~default:"100.0" "MASC_RATE_LIMIT" "Requests per second (per-client global bucket)";
    entry ~default:"150" "MASC_RATE_BURST" "Burst capacity (per-client global bucket)";
    entry ~default:"20.0" "MASC_AGENT_RATE_LIMIT" "Requests per second per resolved agent/token";
    entry ~default:"50" "MASC_AGENT_RATE_BURST" "Burst capacity per resolved agent/token";
    entry ~default:"300.0" "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC"
      "Stale bucket cleanup interval (seconds)";
    entry ~default:"3600.0" "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC"
      "Max age for rate limit entries (seconds)";
  ]

let storage_entries =
  [
    entry ~default:"1000" "MASC_PUBSUB_MAX_MESSAGES"
      "Max pubsub messages per batch";
  ]

let transport_entries =
  [
    entry ~default:"8936" "MASC_GRPC_PORT" "gRPC server port";
    entry ~default:"true" "MASC_GRPC_ENABLED" "Enable gRPC transport";
    entry ~default:"(derived)" "MASC_GRPC_TARGET" "gRPC client target address";
    entry ~default:"48" "MASC_GRPC_STREAM_MAX_BUFFER"
      "Per-subscriber outbound buffer drop threshold.  When the stream has \
       this many unsent events queued, new events are dropped and \
       masc_grpc_events_dropped_total advances.  Stream capacity is 64, \
       default leaves headroom.";
    entry ~default:"8937" "MASC_WS_PORT" "WebSocket server port";
    entry ~default:"true" "MASC_WS_ENABLED" "Enable WebSocket transport";
    entry ~default:"1048576" "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES"
      "Skip WS dashboard deltas for authenticated sessions whose last reported \
       WebSocket.bufferedAmount exceeds this many bytes. 0 disables the gate.";
    entry ~default:"30.0" "MASC_WS_ACK_STALE_THRESHOLD_SEC"
      "Skip WS dashboard deltas for authenticated sessions that have an \
       unacknowledged dashboard/delta older than this many seconds. 0 disables \
       the stale-ack gate.";
    entry ~default:"1048576" "MASC_WS_MAX_INBOUND_FRAME_BYTES"
      "Maximum inbound WebSocket frame payload size accepted before the \
       session is closed with WebSocket close code 1009. 0 disables the \
       frame-size gate.";
    entry ~default:"2097152" "MASC_WS_MAX_INBOUND_MESSAGE_BYTES"
      "Maximum accumulated inbound WebSocket message payload size across \
       fragments before the session is closed with WebSocket close code 1009. \
       0 disables the message-size gate.";
    entry ~default:"true" "MASC_WS_SLICE_INDEX_ENABLED"
      "When true (default), slice-scoped events skip the raw-SSE-forward to \
       authenticated WS sessions whose route does not subscribe to the event's \
       slice. Catch-all events (no slice mapping) still reach every session. \
       masc_ws_slice_fanout_skipped_total advances per skip. RFC #10119 \
       Phase 2. Set to false for emergency rollback only.";
    Env_config_runtime.Transport.h2_snapshot_entry;
    entry ~default:"240" "MASC_STARTUP_WATCHDOG_SEC"
      "Startup watchdog timeout (seconds)";
    Masc_grpc_transport.snapshot_entry;
    entry ~default:"32" "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION"
      "Maximum concurrent JSON-RPC request dispatch fibers admitted from one \
       WebSocket session. 0 disables the per-session admission gate.";
  ]

let keeper_entries =
  [
    entry ~default:"(none)" "MASC_TLA_TRACE"
      "Enable TLA+ trace emission";
  ]

let keeper_execution_entries =
  [
    entry ~default:"4000" "MASC_KEEPER_AUTONOMOUS_MAX_TOKENS"
      "Autonomous execution max tokens";
  ]

let autonomy_entries =
  [
  ]

let dashboard_entries =
  [
    entry ~default:"(none)" "MASC_BENCHMARK_RESULTS_DIR"
      "Benchmark results directory override; None when unset";
    entry ~default:"(none)" "MASC_DASHBOARD_CACHE_MAX_ENTRIES"
      "Dashboard cache max entries (clamped 16-512)";
    entry ~default:"0.50" "MASC_DASHBOARD_CTX_HIGH"
      "Context ratio threshold: high";
    entry ~default:"0.85" "MASC_DASHBOARD_CTX_HANDOFF_IMMINENT"
      "Context ratio threshold: handoff-imminent";
    entry ~default:"0.70" "MASC_DASHBOARD_CTX_PREPARING"
      "Context ratio threshold: preparing";
    entry ~default:"48" "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      "Execution refresh timeout (floor 30, ceiling 300)";
    entry ~default:"120" "MASC_DASHBOARD_EXECUTION_TIMEOUT_SEC"
      "Execution surface compute timeout (floor 5)";
    entry ~default:"30" "MASC_DASHBOARD_EXECUTION_TRUST_TIMEOUT_SEC"
      "Execution-trust surface compute timeout (floor 1)";
    entry ~default:"(none)" "MASC_DASHBOARD_FIXTURE"
      "Dashboard fixture name override";
    entry ~default:"false" "MASC_DASHBOARD_FIXTURES_ENABLED"
      "Enable dashboard test fixtures";
    entry ~default:"3600.0" "MASC_DASHBOARD_KEEPER_ACTION_STALE_SEC"
      "Keeper action-age threshold (seconds, 1 hour)";
    entry ~default:"25" "MASC_DASHBOARD_MISSION_TIMEOUT_SEC"
      "Mission card compute timeout (floor 1)";
    entry ~default:"60" "MASC_DASHBOARD_RENDER_TIMEOUT_SEC"
      "Dashboard render pipeline timeout (floor 5)";
    entry ~default:"0.95" "MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO"
      "Runtime warning context ratio threshold";
    entry ~default:"300.0" "MASC_DASHBOARD_SIGNAL_LIVE_SEC"
      "Duration for signal to count as live (seconds, 5 min)";
    entry ~default:"600.0" "MASC_DASHBOARD_SIGNAL_QUIET_SEC"
      "Duration for borderline quiet warning (seconds, 10 min)";
    entry ~default:"1200.0" "MASC_DASHBOARD_SIGNAL_STALE_SEC"
      "Duration after which a signal is stale (seconds, 20 min)";
    entry ~default:"8" "MASC_DASHBOARD_SHELL_LIGHT_TIMEOUT_SEC"
      "Shell render timeout — light path (floor 0.5)";
    entry ~default:"30" "MASC_DASHBOARD_SHELL_PREWARM_TIMEOUT_SEC"
      "Shell prewarm inner timeout (floor 1)";
    entry ~default:"35" "MASC_DASHBOARD_SHELL_PREWARM_OUTER_TIMEOUT_SEC"
      "Shell prewarm outer timeout (floor 5)";
    entry ~default:"16" "MASC_DASHBOARD_SHELL_TIMEOUT_SEC"
      "Shell render timeout — full path (floor 1)";
    entry ~default:"8" "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      "Transport health timeout";
  ]

(* --- New categories for the 229 missing env vars --- *)

let board_entries =
  [
    entry ~default:"30.0" "MASC_BOARD_FLUSH_INTERVAL_SEC"
      "Flush interval for board persistence (seconds)";
  ]

let cache_entries =
  [
    entry ~default:"1000" "MASC_CACHE_MAX_ENTRIES"
      "Maximum total number of cache entries";
    entry ~default:"102400" "MASC_CACHE_MAX_ENTRY_SIZE"
      "Maximum size of a single cache entry value in bytes (100KB)";
  ]

let channel_gate_entries =
  [
    entry ~default:"4000" "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH"
      "Max content length (floored at 1)";
  ]
  @ declared_entries "channel"

let decision_entries =
  [
    entry ~default:"50" "MASC_DECISION_AUDIT_RING_CAPACITY"
      "Decision audit ring buffer capacity";
  ]

let docker_playground_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_DOCKER_PLAYGROUND"
      "Route Execute through Docker container (feature flag)";
  ]

let keeper_sandbox_entries =
  [
    entry
      ~default:
        "ubuntu:24.04@sha256:cdb5fd928fced577cfecf12c8966e830fcdf42ee481fb0b91904eeddc2fe5eff"
      "MASC_KEEPER_SANDBOX_DOCKER_IMAGE"
      "Digest-pinned Docker image for sandbox_profile=docker";
    entry ~default:"128" "MASC_KEEPER_SANDBOX_PIDS_LIMIT"
      "PID limit for hardened keeper containers";
    entry ~default:"2g" "MASC_KEEPER_SANDBOX_MEMORY"
      "Memory limit for hardened keeper containers";
    entry ~default:"256m" "MASC_KEEPER_SANDBOX_TMPFS_SIZE"
      "Writable /tmp tmpfs size for hardened keeper containers";
    entry ~default:"false" "MASC_KEEPER_SANDBOX_RELAX_FS"
      "Relax Docker sandbox filesystem hardening (writable rootfs + exec /tmp)";
    entry ~default:"" "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"
      "Optional seccomp profile path for hardened keeper containers";
    entry ~default:"false" "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"
      "Fail closed unless Docker reports rootless mode";
    entry ~default:"false" "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
      "Fail closed unless Docker reports userns support";
  ]

let internal_timer_entries =
  [
    entry ~default:"300.0" "MASC_BRIEFING_CACHE_TTL_SEC"
      "Mission briefing cache TTL (seconds, 5 min)";
    entry ~default:"300.0" "MASC_LABEL_QUIET_THRESHOLD_SEC"
      "Dashboard label quiet threshold (seconds, 5 min)";
    entry ~default:"900.0" "MASC_LABEL_STUCK_THRESHOLD_SEC"
      "Dashboard label stuck threshold (seconds, 15 min)";
    entry ~default:"300.0" "MASC_SSE_BUFFER_TTL_SEC"
      "SSE buffer TTL (seconds, 5 min)";
    entry ~default:"300.0" "MASC_STALLED_SESSION_THRESHOLD_SEC"
      "Stalled session threshold (seconds, 5 min)";
  ]

let local_runtime_entries =
  [
    entry ~default:"(none)" "MASC_URL"
      "MASC MCP endpoint URL";
  ]

let message_gc_entries =
  [
  ]

let model_routing_entries =
  [
    entry ~default:"(none)" "MASC_DEFAULT_RUNTIME"
      "Default runtime label; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_MODEL"
      "Default model id; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_PROVIDER"
      "Default provider name; None when unset";
    entry ~default:"3600.0" "MASC_LANE_PREFERENCE_TTL_S"
      "Sticky lane failover preference TTL (seconds, 1 hour); 0 disables";
  ]

let agent_core_sse_entries =
  [
    entry ~default:"2.0" "MASC_AGENT_CORE_SSE_DRAIN_INTERVAL_SEC"
      "SSE drain interval (seconds, floor 0.1)";
  ]

let operator_entries =
  [
    entry ~default:"30.0" "MASC_OPERATOR_CACHE_TTL"
      "Operator snapshot cache TTL (seconds)";
  ]

let orchestrator_entries =
  [
    entry ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"
      "Orchestrator agent name";
    entry ~default:"(none)" Env_config_core.orchestrator_enabled_env_key
      "Orchestrator background loop enabled (feature flag)";
    entry ~default:"300.0" "MASC_ORCHESTRATOR_INTERVAL"
      "Orchestrator check interval (seconds)";
    entry ~default:"2" "MASC_ORCHESTRATOR_MIN_PRIORITY"
      "Orchestrator minimum priority (clamped 0-10)";
  ]

let path_entries =
  [
    entry ~default:"(none)" "MASC_ASSETS_DIR"
      "Assets directory override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_INPUT"
      "Base path input override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_RESOLUTION_SOURCE"
      "Base path resolution source override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_STRICT"
      "Fail-fast on base path resolution issues";
    entry ~default:"(none)" Env_config_core.config_dir_env_key
      "Config directory override; None when unset";
    entry ~default:"(none)" Env_config_core.data_dir_env_key
      "Data directory override; None=<base_path>/data";
    entry ~default:"(host temp directory)" "MASC_BASE_PATH_LEASE_DIR"
      "Cross-process BasePath ownership lease directory";
  ]

let session_entries =
  [
    entry ~default:"3600.0" "MASC_SESSION_MAX_AGE_SEC"
      "Maximum session age before cleanup (seconds, 1 hour)";
    entry ~default:"300.0" "MASC_SESSION_SSE_GRACE_PERIOD_SEC"
      "Grace period after SSE disconnect before reaping transport session (seconds, 5 min)";
  ]

let shutdown_entries =
  [
    entry ~default:"(none)" "MASC_SHUTDOWN_CLEANUP_TIMEOUT"
      "Cleanup timeout during shutdown (seconds)";
    entry ~default:"(none)" "MASC_SHUTDOWN_DRAIN_TIMEOUT"
      "Drain timeout during shutdown (seconds)";
    entry ~default:"(none)" "MASC_SHUTDOWN_FORCE_TIMEOUT"
      "Force exit timeout during shutdown (seconds)";
    entry ~default:"(none)" "MASC_SHUTDOWN_NOTIFY_DELAY"
      "Notify delay before shutdown drain (seconds)";
  ]

let sse_entries =
  [
    entry ~default:"(none)" "MASC_SSE_STREAM_CAPACITY"
      "Per-client SSE event stream capacity (clamped 8-1024)";
  ]

let telemetry_entries =
  [
    entry ~default:"true" Env_config_core.telemetry_enabled_env_key
      "Whether telemetry tracking is enabled";
    entry ~default:"(none)" Env_config_core.log_level_env_key
      "Log level string (debug|info|warn|error)";
    entry ~default:"debug" Env_config_core.log_routine_level_env_key
      "Routine telemetry level (debug|info|warn|error|off)";
    entry ~default:"false" Env_config_core.parse_warn_env_key
      "Whether malformed env parses fail fast";
    entry ~default:"true" "MASC_OTEL_ENABLED"
      "Enable OpenTelemetry span collection";
  ]

let tempo_entries =
  [
    entry ~default:"300.0" "MASC_TEMPO_DEFAULT_INTERVAL_SEC"
      "Polling interval published to operator surfaces (seconds)";
  ]

let test_entries =
  [
    entry ~default:"false" "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"
      "Allow explicit MASC_CONFIG_DIR overrides in test executables";
  ]

let tool_entries =
  [
    entry ~default:"512" "MASC_LIST_PAGE_SIZE"
      "Tool list page size (clamped 10-1024)";
    entry ~default:"true" "MASC_PLACEHOLDER_TOOLS_ENABLED"
      "Show placeholder (unimplemented) tools in tool catalog; set false/0/no to hide";
  ]

let worker_entries =
  [
    entry ~default:"(none)" "MASC_LOCAL_RUNTIME_COOLDOWN_SEC"
      "Local runtime cooldown (seconds); None when unset";
    entry ~default:"(none)" "MASC_LOCAL_RUNTIME_DEBUG"
      "Local runtime debug logging (feature flag)";
  ]

let category_specs () =
  [
    ( "server"
    , server_entries @ path_entries
      @ docker_playground_entries @ test_entries );
    "auth", auth_entries;
    "transport", transport_entries;
    "storage", storage_entries @ cache_entries @ board_entries;
    ( "runtime"
    , runtime_entries
      @ message_gc_entries @ internal_timer_entries
      @ sse_entries @ telemetry_entries
      @ tool_entries
      @ declared_entries "runtime" );
    "rate_limiting", rate_limiting_entries;
    "inference", model_routing_entries @ agent_core_sse_entries @ local_runtime_entries;
    ( "keeper"
    , keeper_runtime_entries @ keeper_entries
      @ docker_playground_entries
      @ keeper_sandbox_entries );
    ( "keeper_execution"
    , keeper_execution_entries @ decision_entries );
    "autonomy", autonomy_entries;
    "dashboard", dashboard_entries;
    "operations", operator_entries @ orchestrator_entries;
    "channel", channel_gate_entries;
    "process", shutdown_entries;
    "worker", worker_entries;
    "web_search", keeper_web_search_entries;
    "session", session_entries @ tempo_entries;
  ]

let all_categories () =
  List.map (fun (name, entries) -> category name entries) (category_specs ())

let valid_config_category_strings = List.map fst (category_specs ())

let to_json ?server_meta ?generated_at ?cat () =
  let categories =
    match cat with
    | None -> all_categories ()
    | Some name ->
        all_categories () |> List.filter (fun (key, _) -> String.equal key name)
  in
  `Assoc
    ((match server_meta with
     | Some meta -> [ ("server", meta) ]
     | None -> [])
    @ (match generated_at with
      | Some value -> [ ("generated_at", `String value) ]
      | None -> [])
    @ [ ("categories", `Assoc categories) ])
