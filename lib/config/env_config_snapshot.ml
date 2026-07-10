(** Env_config_snapshot — shared config introspection categories and JSON envelope.

    This module lives in the [masc_config] sub-library so both [Env_config]
    and root-level wrappers such as [Env_config_introspect] can reuse the same
    category definitions, masking rules, and source attribution logic. *)

let entry = Env_config_snapshot_core.entry
let category = Env_config_snapshot_core.category

let server_entries =
  [
    entry ~default:Masc_network_defaults.masc_http_default_port_s Env_config_core.http_port_env_key "HTTP server port";
    entry ~default:Env_config_core.default_host Env_config_core.host_env_key "Server bind host";
    entry ~default:"(derived)" Env_config_core.http_base_url_env_key "Public HTTP base URL";
    entry ~default:"(derived)" Env_config_core.mcp_url_env_key
      "MASC MCP endpoint URL (derived from base URL when unset)";
    entry ~default:"" "MASC_CLUSTER_NAME" "Cluster name for multi-instance";
    entry ~default:"(cwd)" Env_config_core.base_path_env_key "Base storage directory";
    entry ~default:"(none)" "MASC_BUILD_GIT_COMMIT" "Build git commit hash";
    entry ~default:Masc_network_defaults.masc_http_default_host
      "MASC_HTTP_HOST" "HTTP server listen host";
    entry ~default:"128" "MASC_HTTP_MAX_CONNECTIONS" "HTTP server max connections";
  ]

let auth_entries =
  [
    entry ~sensitive:true ~default:"(none)" Env_config_core.admin_token_env_key
      "Admin authentication token";
    entry ~default:"false" "MASC_ALLOW_ANONYMOUS_MUTATIONS"
      "Allow anonymous mutations (local dev only)";
    entry ~default:"false" "MASC_HTTP_AUTH_STRICT"
      "Require auth for HTTP endpoints";
    entry ~default:"production" Env_config_core.governance_level_env_key
      "Governance level (production|development)";
  ]

let runtime_entries =
  [
    (* RFC-0084 host-config-cleanup-J — MASC_DISPATCH_V2 removed. *)
    entry ~default:"(auto)" Env_config_core.log_level_env_key "Log level override";
    entry ~default:"debug" Env_config_core.log_routine_level_env_key
      "Routine telemetry log level override (debug|info|warn|error|off)";
    entry ~default:"false" Env_config_core.parse_warn_env_key
      "Escalate malformed env parses to Config_error";
    entry ~default:"production" Env_config_core.governance_level_env_key
      "Governance enforcement level";
    entry ~default:"(none)" "MASC_SLOT_YIELD_ENABLED"
      "Release LLM slot during tool execution (feature flag)";
    entry ~default:"true" Env_config_core.telemetry_enabled_env_key
      "Enable telemetry collection";
    entry ~default:"30" "MASC_TELEMETRY_RETENTION_DAYS"
      "Telemetry JSONL day-file retention days. Positive values override; \
       non-positive disables retention.";
    entry ~default:"52428800" "MASC_TELEMETRY_MAX_BYTES"
      "Telemetry JSONL byte cap. Positive values override; non-positive \
       disables byte-cap pruning.";
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
    entry ~default:"true" "MASC_WEBRTC_ENABLED" "Enable WebRTC transport";
    entry ~default:"auto" "MASC_USE_H2" "HTTP mode (auto|h2_only|h1_only)";
    entry ~default:"240" "MASC_STARTUP_WATCHDOG_SEC"
      "Startup watchdog timeout (seconds)";
    entry ~default:"(none)" "MASC_AGENT_TRANSPORT"
      "Agent transport preference";
    entry ~default:"32" "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION"
      "Maximum concurrent JSON-RPC request dispatch fibers admitted from one \
       WebSocket session. 0 disables the per-session admission gate.";
  ]

let inference_entries =
  [
    entry ~default:"30" "MASC_INFERENCE_TIMEOUT_SEC"
      "Inference call timeout (seconds)";
    entry ~default:"true" "MASC_INFERENCE_CACHE_ENABLED"
      "Enable inference result cache";
    entry ~default:"48000" "MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS"
      "Skip caching for prompts exceeding this character count";
    entry ~default:"0.0" "MASC_INFERENCE_CACHE_MAX_TEMP"
      "Cache only temperatures at or below this value (0.0=deterministic only)";
    entry ~default:"300" "MASC_INFERENCE_CACHE_TTL_SEC"
      "Default TTL for inference response cache (seconds)";
    entry ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
      "Spawn cache policy: off or safe_only";
  ]

let keeper_entries =
  [
    entry ~default:"true" "MASC_KEEPER_BOOTSTRAP_ENABLED"
      "Enable keeper auto-bootstrap";
    entry ~default:"300" "MASC_KEEPER_SNAPSHOT_SEC"
      "Keeper keepalive snapshot interval";
    entry ~default:"false" "MASC_KEEPER_DEBUG" "Enable keeper debug logging";
    entry ~default:"0.10" "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD"
      "Daily deliberation budget (USD)";
    entry ~default:"5" "MASC_KEEPER_SUPERVISOR_MAX_RESTARTS"
      "Supervisor max restart attempts";
    entry ~default:"10.0" "MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S"
      "Supervisor backoff base delay (seconds)";
    entry ~default:"300.0" "MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S"
      "Supervisor backoff max delay (seconds)";
    entry ~default:"0.3" "MASC_KEEPER_SELF_PRESERVATION_RATIO"
      "Self-preservation eviction ratio";
    entry ~default:"5" "MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES"
      "Max heartbeat failures before crash";
    entry ~default:"10" "MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES"
      "Max turn failures before crash";
    entry ~default:"true" "MASC_STRUCTURED_STATE"
      "Enable structured JSON state in checkpoints (default true; set to \"false\" to opt out)";
    entry ~default:"(none)" "MASC_TLA_TRACE"
      "Enable TLA+ trace emission";
  ]

let keeper_execution_entries =
  [
    entry ~default:"0.85" "MASC_KEEPER_COMPACT_RATIO"
      "Context compaction trigger ratio";
    entry ~default:"12" "MASC_KEEPER_COMPACT_MAX_MESSAGES"
      "Max messages before compaction";
    entry ~default:"4000" "MASC_KEEPER_COMPACT_MAX_TOKENS"
      "Max tokens before compaction (0=disabled)";
    entry ~default:"0" "MASC_KEEPER_TOOL_COST_MAX_USD"
      "Unified turn accumulated cost ceiling (USD, 0=disabled)";
    entry ~default:"0.4" "MASC_KEEPER_UNIFIED_TEMP" "Unified turn temperature";
    entry ~default:"131072" "MASC_KEEPER_UNIFIED_MAX_TOKENS"
      "Unified turn max output tokens";
    entry ~default:"4000" "MASC_KEEPER_AUTONOMOUS_MAX_TOKENS"
      "Autonomous execution max tokens";
  ]

let keeper_guardrail_entries =
  [
    entry ~default:"0.86" "MASC_KEEPER_RULE_REFLECT_REPETITION"
      "Reflection repetition threshold";
    entry ~default:"0.06" "MASC_KEEPER_RULE_PLAN_GOAL_ALIGNMENT_MAX"
      "Plan goal alignment max";
    entry ~default:"0.10" "MASC_KEEPER_RULE_PLAN_RESPONSE_ALIGNMENT_MAX"
      "Plan response alignment max";
    entry ~default:"0.90" "MASC_KEEPER_RULE_GUARDRAIL_REPETITION"
      "Guardrail repetition threshold";
    entry ~default:"0.04" "MASC_KEEPER_RULE_GUARDRAIL_GOAL_ALIGNMENT_MAX"
      "Guardrail goal alignment max";
    entry ~default:"0.08" "MASC_KEEPER_RULE_GUARDRAIL_RESPONSE_ALIGNMENT_MAX"
      "Guardrail response alignment max";
    entry ~default:"0.70" "MASC_KEEPER_RULE_GUARDRAIL_CONTEXT_MIN"
      "Guardrail context minimum";
  ]

let autonomy_entries =
  [
    entry ~default:"3" "MASC_AUTONOMY_QUIET_START" "Quiet hours start (0-23)";
    entry ~default:"7" "MASC_AUTONOMY_QUIET_END" "Quiet hours end (0-23)";
    entry ~default:"12" "MASC_AUTONOMY_MAX_STARVATION_TICKS"
      "Max agent starvation ticks";
    entry ~default:"0.15" "MASC_AUTONOMY_STARVATION_BONUS_COEF"
      "Starvation bonus coefficient for agent selection";
    entry ~default:"0.7" "MASC_AUTONOMY_THOMPSON_WEIGHT"
      "Thompson sampling weight";
    entry ~default:"0.95" "MASC_AUTONOMY_VOTE_DECAY_FACTOR"
      "Vote decay factor";
    entry ~default:"0.5" "MASC_GUARD_PENALTY_BETA"
      "Guard penalty beta for B-SIM calibration (floor 0)";
  ]

let level2_entries =
  [
    entry ~default:"0.85" "MASC_DRIFT_THRESHOLD" "Drift detection threshold";
    entry ~default:"0.4" "MASC_DRIFT_JACCARD_WEIGHT" "Drift Jaccard weight";
    entry ~default:"0.6" "MASC_DRIFT_COSINE_WEIGHT" "Drift cosine weight";
    entry ~default:"0.075" "MASC_HEBBIAN_RATE" "Hebbian learning rate";
    entry ~default:"0.01" "MASC_HEBBIAN_DECAY" "Hebbian decay rate";
    entry ~default:"100" "MASC_LOCK_WARN_MS"
      "Lock contention warning threshold (ms)";
  ]

let dashboard_entries =
  [
    entry ~default:"(none)" "MASC_BENCHMARK_RESULTS_DIR"
      "Benchmark results directory override; None when unset";
    entry ~default:"(none)" "MASC_DASHBOARD_CACHE_MAX_ENTRIES"
      "Dashboard cache max entries (clamped 16-512)";
    entry ~default:"0.50" "MASC_DASHBOARD_CTX_COMPACTING"
      "Context ratio threshold: compacting";
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
    entry ~default:"(none)" "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED"
      "Governance judge background loop (feature flag)";
    entry ~default:"60" "MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC"
      "Dashboard governance judge interval (clamped >=15 seconds)";
    entry ~default:"0.9" "MASC_DASHBOARD_HEALTH_CTX_CRITICAL"
      "Health scoring: context ratio critical threshold";
    entry ~default:"0.8" "MASC_DASHBOARD_HEALTH_CTX_WARN"
      "Health scoring: context ratio warning threshold";
    entry ~default:"20.0" "MASC_DASHBOARD_HEALTH_PENALTY_CRITICAL"
      "Health penalty for critical context ratio";
    entry ~default:"10.0" "MASC_DASHBOARD_HEALTH_PENALTY_WARN"
      "Health penalty for warning context ratio";
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
    (* RFC-0138 Phase 3 Step 4 — MASC_NAMESPACE_TRUTH_*_TIMEOUT_S env
       knobs retired.  After Step 3 (#16738) wired /project-snapshot
       through Dashboard_snapshot, the fallback path that consumed
       those tunables runs at most once per process lifetime; values
       are now module constants in
       [Server_dashboard_http_namespace_truth]. *)
  ]

(* --- New categories for the 229 missing env vars --- *)

let board_entries =
  [
    entry ~default:"(none)" "MASC_BOARD_BACKEND"
      "Board backend type (e.g. jsonl, pg); None when unset";
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

let cancellation_entries =
  [
    entry ~default:"3600.0" "MASC_CANCELLATION_TOKEN_MAX_AGE_SEC"
      "Token cleanup max age (seconds)";
  ]

let channel_gate_entries =
  [
    entry ~default:"(none)" "MASC_CHANNEL_GATE_DEDUP_TTL_SEC"
      "Dedup TTL (seconds, clamped 10-3600)";
    entry ~default:"(none)" "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH"
      "Max content length (clamped 100-16000)";
    entry ~default:"30" "MASC_DISCORD_STATUS_STALE_SEC"
      "Discord status stale threshold (seconds)";
    entry ~default:"30" "MASC_IMESSAGE_STATUS_STALE_SEC"
      "iMessage status stale threshold (seconds)";
  ]

let compaction_entries =
  [
    entry ~default:"0.95" "MASC_CONTEXT_RATIO_HARD_CAP"
      "Absolute ceiling for compaction ratio_gate (clamped 0.80-0.99)";
  ]

let decision_entries =
  [
    entry ~default:"50" "MASC_DECISION_AUDIT_RING_CAPACITY"
      "Decision audit ring buffer capacity";
    entry ~default:"0" "MASC_DECISION_LAYER_LEVEL"
      "Decision layer level (0=off, 1=audit, 2+=extended)";
  ]

let docker_playground_entries =
  [
    entry ~default:"keeper-playground" "MASC_KEEPER_DOCKER_CONTAINER"
      "Docker container name for keeper playground";
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
    entry ~default:"(none)" "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"
      "Optional seccomp profile path for hardened keeper containers";
    entry ~default:"false" "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"
      "Fail closed unless Docker reports rootless mode";
    entry ~default:"false" "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
      "Fail closed unless Docker reports userns support";
    entry ~default:"true" "MASC_KEEPER_SANDBOX_GIT_DISPATCH"
      "Enable legacy Docker git/gh bridge dispatch when hard mode is off";
    entry ~default:"true" "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED"
      "Best-effort cleanup for stale MASC keeper sandbox containers";
    entry ~default:"21600" "MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC"
      "Age threshold for stale keeper sandbox container cleanup";
    entry ~default:"300" "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC"
      "Minimum seconds between automatic keeper sandbox cleanup sweeps";
  ]

let economy_entries =
  [
    entry ~default:"false" "MASC_ECONOMY_ENABLED"
      "Agent economy feature flag";
    entry ~default:"5.0" "MASC_ECONOMY_FRUGAL_THRESHOLD"
      "Frugal behavior threshold";
    entry ~default:"0.0" "MASC_ECONOMY_HUSTLE_THRESHOLD"
      "Hustle behavior threshold";
    entry ~default:"5.0" "MASC_ECONOMY_INITIAL_BALANCE"
      "Initial agent balance";
    entry ~default:"1.0" "MASC_ECONOMY_REWARD_BOARD_POST"
      "Reward for a board post";
    entry ~default:"0.5" "MASC_ECONOMY_REWARD_MENTION_RESPONSE"
      "Reward for responding to a mention";
    entry ~default:"10.0" "MASC_ECONOMY_REWARD_TASK_DONE"
      "Reward for completing a task";
    entry ~default:"0.5" "MASC_ECONOMY_REWARD_UPVOTE"
      "Reward for receiving an upvote";
  ]

let internal_timer_entries =
  [
    entry ~default:"300.0" "MASC_BRIEFING_CACHE_TTL_SEC"
      "Mission briefing cache TTL (seconds, 5 min)";
    entry ~default:"300.0" "MASC_KEEPER_BOOTSTRAP_WINDOW_SEC"
      "Keeper world observation bootstrap window (seconds, 5 min)";
    entry ~default:"300.0" "MASC_LABEL_QUIET_THRESHOLD_SEC"
      "Dashboard label quiet threshold (seconds, 5 min)";
    entry ~default:"900.0" "MASC_LABEL_STUCK_THRESHOLD_SEC"
      "Dashboard label stuck threshold (seconds, 15 min)";
    entry ~default:"300.0" "MASC_METRICS_FLUSH_SEC"
      "Tool metrics flush interval (seconds, 5 min)";
    entry ~default:"300.0" "MASC_SSE_BUFFER_TTL_SEC"
      "SSE buffer TTL (seconds, 5 min)";
    entry ~default:"300.0" "MASC_STALLED_SESSION_THRESHOLD_SEC"
      "Stalled session threshold (seconds, 5 min)";
  ]

let keeper_alert_entries =
  [
    entry ~default:"60.0" "MASC_ALERT_DEDUP_WINDOW_SEC"
      "Alert dedup window (seconds, floor 5)";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_BOARD_ENABLED"
      "Board fanout for keeper alerts (feature flag)";
    entry ~default:"keeper-alert-bot" "MASC_KEEPER_ALERT_BOARD_AUTHOR"
      "Board alert author name";
    entry ~default:"keeper-alert" "MASC_KEEPER_ALERT_BOARD_HEARTH"
      "Board alert hearth name";
    entry ~default:"internal" "MASC_KEEPER_ALERT_BOARD_VISIBILITY"
      "Board alert visibility level";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_ENABLED"
      "Master switch for keeper alert detection/fanout (feature flag)";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_GITHUB_ENABLED"
      "GitHub issue fanout (feature flag)";
    entry ~default:"keeper-alert" "MASC_KEEPER_ALERT_GITHUB_LABEL"
      "GitHub label for alert issues";
    entry ~default:"0.85" "MASC_KEEPER_ALERT_GITHUB_MIN_SCORE"
      "Minimum score for GitHub issue fanout";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_GITHUB_REPO"
      "GitHub repo for alert issues (empty=disabled)";
    entry ~default:"1200" "MASC_KEEPER_ALERT_MAX_BODY_CHARS"
      "Maximum alert body chars for external fanout";
    entry ~default:"2" "MASC_KEEPER_ALERT_MAX_RETRIES"
      "Retry count for each fanout channel";
    entry ~default:"0.70" "MASC_KEEPER_ALERT_MIN_SCORE"
      "Minimum score to trigger alert fanout";
    entry ~default:"250" "MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS"
      "Base retry delay in milliseconds (exponential backoff)";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_SLACK_DM_ENABLED"
      "Slack DM fanout (feature flag)";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_SLACK_DM_USER_ID"
      "Slack DM target user ID (empty=disabled)";
    entry ~default:"(none)" "MASC_KEEPER_ALERT_SLACK_ENABLED"
      "Slack webhook fanout (feature flag)";
    entry ~sensitive:true ~default:"(none)" "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL"
      "Slack webhook URL for alerts (empty=disabled)";
  ]

let keeper_bootstrap_entries =
  [
    entry ~default:"10000" "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
      "Maximum concurrently active keepers";
    entry ~default:"10000" "MASC_KEEPER_BOOTSTRAP_MAX_SCAN"
      "Max keeper meta files to scan during bootstrap";
    entry ~default:"3600.0" "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC"
      "Keeper stale turn threshold (seconds)";
  ]

let keeper_runtime_entries =
  [
    entry ~default:"enforce" "MASC_RUNTIME_ATTEMPT_LIVENESS"
      "Runtime attempt-liveness gate mode (off|observe|enforce). RFC-0022 \
       Explicit values must be canonical; invalid values raise a config error.";
  ]

let keeper_grpc_entries =
  [
    entry ~default:"5" "MASC_KEEPER_GRPC_MAX_RECONNECT"
      "Max gRPC reconnect attempts (clamped 1-20)";
    entry ~default:"5.0" "MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC"
      "Backoff delay between gRPC reconnect attempts (clamped 1-60 seconds)";
  ]

let keeper_keepalive_entries =
  [
    entry ~default:"30" "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"
      "Heartbeat cycle interval (clamped 5-300 seconds)";
    entry ~default:"0.2" "MASC_KEEPER_HEARTBEAT_JITTER_FACTOR"
      "Jitter factor applied to heartbeat interval (clamped 0-0.5)";
    entry ~default:"4" "MASC_KEEPER_IDLE_SKIP_THRESHOLD"
      "Consecutive idle tool repetitions before Skip (clamped 2-20)";
    entry ~default:"10" "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS"
      "Max idle turns for scheduled autonomous turns (clamped 2-50)";
    entry ~default:"15" "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"
      "Max idle turns for reactive (board/mention) turns (clamped 2-50)";
    entry ~default:"120.0" "MASC_KEEPER_MAX_SILENCE_SEC"
      "Max seconds since last heartbeat before presence sync required";
    entry ~default:"(none)" "MASC_KEEPER_OAS_TIMEOUT_SEC"
      "Legacy optional override for OAS call timeout. When set, clamped to [30, turn_timeout_sec].";
    entry ~default:"2.0" "MASC_KEEPER_SLEEP_CHUNK_SEC"
      "Interruptible sleep chunk size (seconds, clamped 0.1-10)";
    entry ~default:"(none)" "MASC_KEEPER_SMART_HEARTBEAT"
      "Adaptive heartbeat scheduling in keepalive loop (feature flag)";
    entry ~default:"3" "MASC_KEEPER_TURN_LIVELOCK_MAX_ATTEMPTS"
      "Max dispatch attempts for the same keeper turn id before livelock guard blocks";
    entry ~default:"1800.0" "MASC_KEEPER_TURN_LIVELOCK_STUCK_AFTER_SEC"
      "Max seconds a keeper turn id may stay active before livelock guard blocks";
    entry ~default:"8" "MASC_KEEPER_TURN_CHAT_WAITING_CAP"
      "Max chat requests parked behind one keeper turn admission slot (floored at 1)";
    entry ~default:"600.0" "MASC_KEEPER_TURN_TIMEOUT_SEC"
      "Wall-clock timeout for a single unified turn (clamped 60-900 seconds)";
    entry ~default:"1800.0" "MASC_KEEPER_ATTEMPT_WATCHDOG_SAFETY_CAP_SEC"
      "Deprecated compatibility knob; not applied as a MASC timeout around active provider/tool execution";
    entry ~default:"(none)" "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC"
      "Parsed compatibility knob; keeper path does not forward until tool execution is excluded";
    entry ~default:"(none)" "MASC_KEEPER_WORK_AS_HEARTBEAT"
      "Successful workspace heartbeat after turn counts as presence proof (feature flag)";
  ]

let keeper_metrics_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_METRICS_MAX_BYTES"
      "Max metrics file size before rotation (10MB)";
    entry ~default:"1" "MASC_KEEPER_METRICS_MAX_ROTATED"
      "Number of rotated files to keep";
  ]

let keeper_health_entries =
  [
    entry ~default:"0.0" "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC"
      "Durable keeper event-queue backlog age before full-health degrades (seconds)";
  ]

let keeper_proactive_entries =
  [
    entry ~default:"3" "MASC_KEEPER_PROACTIVE_MAX_ATTEMPTS"
      "Max proactive generation attempts (clamped 1-10)";
    entry ~default:"2" "MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT"
      "Max exponent for no-op proactive cooldown backoff (clamped 0-8)";
    entry ~default:"4" "MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS"
      "Max idle-decay periods for proactive cooldown decay (clamped 0-16)";
    entry ~default:"100" "MASC_KEEPER_STAGE_TIMING_RING_SIZE"
      "Stage timing ring buffer size for profiling (clamped 10-1000)";
  ]

let keeper_supervisor_entries =
  [
    entry ~default:"3600.0" "MASC_KEEPER_DEAD_TTL_SEC"
      "Dead tombstone TTL before cleanup (seconds, floor 60)";
    entry ~default:"(none)" "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC"
      "Paused keeper meta file TTL (seconds, 24 hours, floor 300)";
    entry ~default:"2" "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES"
      "Self-preservation minimum crashed candidates to trigger";
    entry ~default:"30.0" "MASC_KEEPER_SUPERVISOR_SWEEP_SEC"
      "Supervisor sweep interval (seconds)";
  ]

let keeper_tool_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_LLM_RERANK_RUNTIME"
      "Named runtime profile for LLM reranker";
    entry ~default:"3" "MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES"
      "Max consecutive failures for same tool+args before blocking (clamped 2-20)";
    entry ~default:"(none)" "MASC_KEEPER_TOOL_AFFINITY_K"
      "Max pre-populated tools from affinity (clamped 0-20)";
    entry ~default:"(none)" "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS"
      "Lookback window for tool affinity (clamped 1-30 days)";
    entry ~default:"(none)" "MASC_KEEPER_TOOL_DECAY_TURNS"
      "Tool decay turns for discovered tool pruning";
  ]

let local_runtime_entries =
  [
    entry ~default:"(none)" "MASC_URL"
      "MASC MCP endpoint URL";
  ]

let lock_entries =
  [
    entry ~default:"300.0" "MASC_LOCK_EXPIRY_WARNING_SEC"
      "Lock expiry warning threshold (seconds before expiry)";
    entry ~default:"120.0" "MASC_LOCK_TIMEOUT_SEC"
      "Default lock timeout (seconds, 2 min)";
  ]

module Memory_os_defaults = Env_config_keeper.KeeperMemoryOs

let optional_default_to_display = function
  | None -> "(none)"
  | Some value -> value
;;

(* Env-var names come from Env_config_keeper.KeeperMemoryOs (the reader
   module), never from re-spelled literals: a registry entry whose env var
   nothing reads is a silent no-op reported as source=env. *)
let memory_entries =
  [
    entry
      ~default:(string_of_bool Memory_os_defaults.recall_enabled_default)
      Memory_os_defaults.recall_env_key
      "Memory OS recall prompt injection enabled; invalid values fail closed";
    entry
      ~default:(string_of_bool Memory_os_defaults.librarian_enabled_default)
      Memory_os_defaults.librarian_env_key
      "Memory OS post-turn librarian extraction enabled; invalid values fail closed";
    entry
      ~default:(string_of_int Memory_os_defaults.librarian_cadence_turns_default)
      Memory_os_defaults.librarian_cadence_turns_env_key
      "Turns between librarian extraction attempts per keeper (floor 1)";
    entry
      ~default:(string_of_int Memory_os_defaults.librarian_max_messages_default)
      Memory_os_defaults.librarian_max_messages_env_key
      "Recent-message window for librarian extraction (floor 1)";
    entry
      ~default:
        (Memory_os_defaults.float_default_to_display Memory_os_defaults.librarian_timeout_sec_default)
      Memory_os_defaults.librarian_timeout_sec_env_key
      "Provider timeout for librarian extraction in seconds";
    entry
      ~default:(string_of_int Memory_os_defaults.librarian_max_tokens_default)
      Memory_os_defaults.librarian_max_tokens_env_key
      "Output token cap for librarian extraction (applied as min with provider max_tokens, floor 1)";
    entry
      ~default:
        (optional_default_to_display Memory_os_defaults.librarian_runtime_id_default)
      Memory_os_defaults.librarian_runtime_id_env_key
      "Optional runtime id override for librarian extraction; (none) displays the empty default";
    entry
      ~default:(string_of_int Memory_os_defaults.librarian_global_slot_default)
      Memory_os_defaults.librarian_global_slot_env_key
      "Fleet-wide concurrency gate for librarian provider calls; 0 disables";
    entry
      ~default:(string_of_bool Memory_os_defaults.gc_enabled_default)
      Memory_os_defaults.gc_env_key
      "Per-keeper Memory OS GC maintenance fiber kill switch; invalid values fail closed";
    entry
      ~default:(string_of_bool Memory_os_defaults.shared_consolidator_enabled_default)
      Memory_os_defaults.shared_consolidator_env_key
      "Tier-2 shared Memory OS consolidator kill switch; invalid values fail closed";
    entry
      ~default:(string_of_bool Memory_os_defaults.consolidation_enabled_default)
      Memory_os_defaults.consolidation_env_key
      "Per-keeper Memory OS consolidation maintenance fiber kill switch; invalid values fail closed";
    entry
      ~default:
        (optional_default_to_display
           Memory_os_defaults.consolidation_runtime_id_default)
      Memory_os_defaults.consolidation_runtime_id_env_key
      "Optional runtime id override for Memory OS consolidation; (none) displays the empty default";
  ]

let message_gc_entries =
  [
    entry ~default:"200" "MASC_MESSAGE_MAX_COUNT"
      "Maximum message files retained per workspace";
  ]

let model_routing_entries =
  [
    entry ~default:"(none)" "MASC_DEFAULT_RUNTIME"
      "Default runtime label; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_MODEL"
      "Default model id; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_PROVIDER"
      "Default provider name; None when unset";
    entry ~default:"task" "MASC_GOAL_DISPATCH_RUNTIME"
      "Goal dispatch runtime type";
    entry ~default:"(none)" "MASC_ROUTING_RUNTIME"
      "Routing runtime for team session routing";
  ]

let oas_sse_entries =
  [
    entry ~default:"2.0" "MASC_OAS_SSE_DRAIN_INTERVAL_SEC"
      "SSE drain interval (seconds, floor 0.1)";
  ]

let operator_entries =
  [
    entry ~default:"30.0" "MASC_OPERATOR_CACHE_TTL"
      "Operator snapshot cache TTL (seconds)";
    entry ~default:"(none)" "MASC_OPERATOR_JUDGE_ENABLED"
      "Operator judge background loop (feature flag)";
    entry ~default:"60" "MASC_OPERATOR_JUDGE_INTERVAL_SEC"
      "Operator judge interval (clamped >=15 seconds)";
    entry ~default:"60" "MASC_OPERATOR_JUDGE_WORKSPACE_TTL_SEC"
      "Workspace TTL for operator judge cleanup (clamped >=15 seconds)";
    entry ~default:"300" "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC"
      "Session TTL for operator judge cleanup (clamped >=30 seconds)";
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
    entry ~default:"300" "MASC_ORCHESTRATOR_TIMEOUT"
      "Orchestrator timeout (clamped 10-3600 seconds)";
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
    entry ~default:"(none)" Env_config_core.personas_dir_env_key
      "Personas directory override; None when unset";
  ]

let procedural_memory_entries =
  [
    entry ~default:"0.7" "MASC_PROC_MIN_CONFIDENCE"
      "Minimum confidence for crystallization (clamped 0-1)";
    entry ~default:"3" "MASC_PROC_MIN_EVIDENCE"
      "Minimum evidence count for crystallization (clamped >=1)";
  ]

let pulse_entries =
  [
    entry ~default:"3" "MASC_PULSE_MAX_CONSUMER_FAILURES"
      "Max consecutive consumer failures before recovery (clamped >=1)";
  ]

let session_entries =
  [
    entry ~default:"3600.0" "MASC_SESSION_MAX_AGE_SEC"
      "Maximum session age before cleanup (seconds, 1 hour)";
    entry ~default:"60.0" "MASC_SESSION_RATE_LIMIT_WINDOW_SEC"
      "Rate limit window (seconds)";
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

let smart_heartbeat_entries =
  [
    entry ~default:"30.0" "MASC_SMART_HB_BASE_INTERVAL_SEC"
      "Base heartbeat interval (seconds, clamped 5-300)";
    entry ~default:"3.0" "MASC_SMART_HB_IDLE_MULTIPLIER"
      "Idle multiplier for interval (clamped 1-10)";
    entry ~default:"300.0" "MASC_SMART_HB_IDLE_THRESHOLD_SEC"
      "Idle threshold before multiplier kicks in (seconds, clamped 60-3600)";
  ]

let sse_entries =
  [
    entry ~default:"(none)" "MASC_SSE_STREAM_CAPACITY"
      "Per-client SSE event stream capacity (clamped 8-1024)";
  ]

let task_entries =
  [
    entry ~default:"3600.0" "MASC_CLAIM_TTL_SECONDS"
      "Maximum time a task stays claimed without heartbeat before auto-release (seconds)";
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
    entry ~default:"(none)" "MASC_OTEL_ENABLED"
      "Enable OpenTelemetry span collection";
  ]

let tempo_entries =
  [
    entry ~default:"300.0" "MASC_TEMPO_DEFAULT_INTERVAL_SEC"
      "Default polling interval (seconds)";
    entry ~default:"600.0" "MASC_TEMPO_MAX_INTERVAL_SEC"
      "Maximum polling interval for idle tempo (seconds)";
    entry ~default:"60.0" "MASC_TEMPO_MIN_INTERVAL_SEC"
      "Minimum polling interval for urgent tempo (seconds)";
  ]

let test_entries =
  [
    entry ~default:"false" "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE"
      "Allow explicit MASC_BASE_PATH override handling in test executables";
    entry ~default:"false" "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"
      "Allow explicit MASC_CONFIG_DIR and MASC_PERSONAS_DIR overrides in test executables";
  ]

let timeout_entries =
  [
    entry ~default:"100" "MASC_EVENT_BUFFER_SIZE"
      "A2A event buffer size per subscription";
    entry ~default:"30.0" "MASC_SSE_KEEPALIVE_SEC"
      "SSE keepalive interval (seconds, floor 1)";
  ]

let tool_entries =
  [
    entry ~default:"(none)" "MASC_FULL_SURFACE"
      "Include hidden/developer tools in tool list (feature flag)";
    entry ~default:"512" "MASC_LIST_PAGE_SIZE"
      "Tool list page size (clamped 10-1024)";
    entry ~default:"(none)" "MASC_PLACEHOLDER_TOOLS_ENABLED"
      "Enable placeholder tool exposure";
    entry ~default:"(none)" "MASC_PUBLIC_TOOLS_EXTRA"
      "Extra public tools (comma-separated names); None when unset";
    entry ~default:"2" "MASC_TOOL_READONLY_RETRY_LIMIT"
      "Read-only tool retry limit";
  ]

let web_search_entries =
  [
    entry ~default:"(none)" "MASC_SEARXNG_URL"
      "SearXNG instance URL; None when unset";
    entry ~default:"30.0" "MASC_WEB_SEARCH_CACHE_TTL_SEC"
      "Web search cache TTL (seconds, floor 0)";
    entry ~default:"(none)" "MASC_WEB_SEARCH_FALLBACKS"
      "Web search fallback providers; None when unset";
    entry ~default:"(none)" "MASC_WEB_SEARCH_PROVIDER"
      "Web search provider override; None when unset";
    entry ~default:"(none)" "MASC_WEB_SEARCH_PROVIDER_ORDER"
      "Web search provider fallback order; None when unset";
    entry ~default:"30" "MASC_WEB_SEARCH_RATE_LIMIT_MAX_CALLS"
      "Web search rate limit max calls per window (floor 1)";
    entry ~default:"30.0" "MASC_WEB_SEARCH_RATE_LIMIT_WINDOW_SEC"
      "Web search rate limit window (seconds, floor 1)";
    entry ~default:"15" "MASC_WEB_SEARCH_TIMEOUT_SEC"
      "Web search timeout (clamped 1-60 seconds)";
  ]

let worker_entries =
  [
    entry ~default:"(none)" "MASC_LOCAL_RUNTIME_COOLDOWN_SEC"
      "Local runtime cooldown (seconds); None when unset";
    entry ~default:"(none)" "MASC_LOCAL_RUNTIME_DEBUG"
      "Local runtime debug logging (feature flag)";
    entry ~default:"60" "MASC_LOCAL_WORKER_HEARTBEAT_SEC"
      "Local worker heartbeat interval (seconds, clamped >=1)";
    entry ~default:"1024" "MASC_LOCAL_WORKER_MAX_TOKENS"
      "Local worker max tokens per request (clamped >=1)";
  ]

let worker_runtime_entries =
  [
    entry ~default:"(none)" "MASC_WORKER_RUNTIME_BACKEND"
      "Worker execution backend (e.g. docker, local); None when unset";
    entry ~default:"(none)" "MASC_WORKER_RUNTIME_DOCKER_IMAGE"
      "Docker image for worker runtime; None when unset";
    entry ~default:"(none)" "MASC_WORKER_RUNTIME_HOST_MCP_BASE_URL"
      "Host MCP base URL for worker runtime; None when unset";
  ]

let zombie_cleanup_entries =
  [
    entry ~default:"3600.0" "MASC_KEEPER_ZOMBIE_THRESHOLD_SEC"
      "Threshold for keeper agents zombie detection (1 hour grace)";
    entry ~default:"60.0" "MASC_ZOMBIE_CLEANUP_INTERVAL_SEC"
      "Cleanup loop interval for zombie detection (seconds)";
    entry ~default:"300.0" "MASC_ZOMBIE_THRESHOLD_SEC"
      "Threshold for considering a resource as zombie (seconds)";
  ]

let all_categories () =
  [
    category "server"
      (server_entries @ path_entries
       @ docker_playground_entries @ test_entries);
    category "auth" auth_entries;
    category "transport" transport_entries;
    category "storage" (storage_entries @ cache_entries @ memory_entries @ board_entries);
    category "runtime"
      (runtime_entries @ task_entries
       @ message_gc_entries @ pulse_entries @ internal_timer_entries
       @ timeout_entries @ sse_entries @ telemetry_entries
       @ tool_entries);
    category "rate_limiting" rate_limiting_entries;
    category "inference"
      (inference_entries @ model_routing_entries @ oas_sse_entries
       @ local_runtime_entries);
    category "keeper"
      (keeper_entries @ keeper_alert_entries @ keeper_bootstrap_entries
       @ keeper_keepalive_entries @ keeper_metrics_entries
       @ keeper_health_entries
       @ docker_playground_entries
       @ keeper_sandbox_entries);
    category "keeper_execution"
      (keeper_execution_entries @ compaction_entries @ decision_entries
       @ keeper_tool_entries @ keeper_runtime_entries
       @ keeper_proactive_entries @ keeper_grpc_entries);
    category "keeper_guardrails" keeper_guardrail_entries;
    category "autonomy" (autonomy_entries @ keeper_supervisor_entries);
    category "level2" level2_entries;
    category "dashboard" dashboard_entries;
    category "economy" economy_entries;
    category "governance"
      (operator_entries @ orchestrator_entries @ smart_heartbeat_entries);
    category "channel" channel_gate_entries;
    category "process"
      (shutdown_entries
       @ cancellation_entries @ zombie_cleanup_entries @ lock_entries
       @ procedural_memory_entries);
    category "worker" (worker_entries @ worker_runtime_entries);
    category "web_search" web_search_entries;
    category "session" (session_entries @ tempo_entries);
  ]

let valid_config_category_strings =
  all_categories () |> List.map fst

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
