(** Env_config_snapshot — shared config introspection categories and JSON envelope.

    This module lives in the [masc_config] sub-library so both [Env_config]
    and root-level wrappers such as [Env_config_introspect] can reuse the same
    category definitions, masking rules, and source attribution logic. *)

let mask_sensitive value =
  if String.length value <= 4 then "***"
  else
    let visible = min 4 (String.length value) in
    String.sub value 0 visible ^ "***"

let is_sensitive_name name =
  let lower = String.lowercase_ascii name in
  List.exists
    (fun pat ->
      let rec contains_at i =
        if i + String.length pat > String.length lower then false
        else if String.sub lower i (String.length pat) = pat then true
        else contains_at (i + 1)
      in
      contains_at 0)
    [ "token"; "password"; "secret"; "key"; "credential";
      "neo4j_url"; "supabase" ]

type entry = {
  env_name : string;
  description : string;
  default_display : string;
  sensitive : bool;
}

let entry ?(sensitive = false) ~default env_name description =
  let sensitive = sensitive || is_sensitive_name env_name in
  { env_name; description; default_display = default; sensitive }

let read_entry e =
  let raw = Env_config_core.trim_opt (Sys.getenv_opt e.env_name) in
  let display_value =
    match raw with
    | None -> None
    | Some v when e.sensitive -> Some (mask_sensitive v)
    | Some v -> Some v
  in
  `Assoc
    [
      ("env", `String e.env_name);
      ("description", `String e.description);
      ("value", Json_util.string_opt_to_json display_value);
      ("default", `String e.default_display);
      ("source", `String (if raw = None then "default" else "env"));
      ("sensitive", `Bool e.sensitive);
    ]

let category name entries =
  (name, `List (List.map read_entry entries))

let server_entries =
  [
    entry ~default:Masc_network_defaults.masc_http_default_port_s "MASC_HTTP_PORT" "HTTP server port";
    entry ~default:Env_config_core.default_host "MASC_HOST" "Server bind host";
    entry ~default:"(derived)" "MASC_HTTP_BASE_URL" "Public HTTP base URL";
    entry ~default:"" "MASC_CLUSTER_NAME" "Cluster name for multi-instance";
    entry ~default:"(cwd)" "MASC_BASE_PATH" "Base storage directory";
    entry ~default:"(none)" "MASC_BUILD_GIT_COMMIT" "Build git commit hash";
    entry ~default:"127.0.0.1" "MASC_HTTP_HOST" "HTTP server listen host";
    entry ~default:"128" "MASC_HTTP_MAX_CONNECTIONS" "HTTP server max connections";
  ]

let auth_entries =
  [
    entry ~sensitive:true ~default:"(none)" "MASC_ADMIN_TOKEN"
      "Admin authentication token";
    entry ~default:"false" "MASC_ALLOW_ANONYMOUS_MUTATIONS"
      "Allow anonymous mutations (local dev only)";
    entry ~default:"true" "MASC_TOOL_AUTH_STRICT"
      "Require auth for all tool calls";
    entry ~default:"false" "MASC_HTTP_AUTH_STRICT"
      "Require auth for HTTP endpoints";
  ]

let runtime_entries =
  [
    entry ~default:"(none)" "MASC_CDAL_ENABLED"
      "Contract-driven agent loop proof capture (feature flag)";
    entry ~default:"true" "MASC_DISPATCH_V2" "Enable V2 dispatch engine";
    entry ~default:"(auto)" "MASC_LOG_LEVEL" "Log level override";
    entry ~default:"false" "MASC_PARSE_WARN" "Enable JSON parse warnings";
    entry ~default:"production" "MASC_GOVERNANCE_LEVEL"
      "Governance enforcement level";
    entry ~default:"(none)" "MASC_AUTO_RESPOND" "Auto-respond mode";
    entry ~default:"(none)" "MASC_SLOT_YIELD_ENABLED"
      "Release LLM slot during tool execution (feature flag)";
    entry ~default:"(none)" "MASC_TEAM_SESSION_ROUTER_JUDGE"
      "Team session routing judge for dispatch (feature flag)";
    entry ~default:"true" "MASC_TELEMETRY_ENABLED"
      "Enable telemetry collection";
  ]

let rate_limiting_entries =
  [
    entry ~default:"100.0" "MASC_RATE_LIMIT" "Requests per second";
    entry ~default:"150" "MASC_RATE_BURST" "Burst capacity";
    entry ~default:"300.0" "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC"
      "Stale bucket cleanup interval (seconds)";
    entry ~default:"3600.0" "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC"
      "Max age for rate limit entries (seconds)";
  ]

let storage_entries =
  [
    entry ~default:"filesystem" "MASC_STORAGE_TYPE"
      "Backend storage type (filesystem only)";
    entry ~default:"1000" "MASC_PUBSUB_MAX_MESSAGES"
      "Max pubsub messages per batch";
  ]

let transport_entries =
  [
    entry ~default:"8936" "MASC_GRPC_PORT" "gRPC server port";
    entry ~default:"true" "MASC_GRPC_ENABLED" "Enable gRPC transport";
    entry ~default:"(derived)" "MASC_GRPC_TARGET" "gRPC client target address";
    entry ~default:"8937" "MASC_WS_PORT" "WebSocket server port";
    entry ~default:"true" "MASC_WS_ENABLED" "Enable WebSocket transport";
    entry ~default:"true" "MASC_WEBRTC_ENABLED" "Enable WebRTC transport";
    entry ~default:"auto" "MASC_USE_H2" "HTTP mode (auto|h2_only|h1_only)";
    entry ~default:"240" "MASC_STARTUP_WATCHDOG_SEC"
      "Startup watchdog timeout (seconds)";
    entry ~default:"(none)" "MASC_AGENT_TRANSPORT"
      "Agent transport preference";
    entry ~default:"false" "MASC_OPENAI_COMPAT"
      "Enable OpenAI-compatible endpoint";
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
    entry ~default:"true" "MASC_RELAY_CALIBRATION_ENABLED"
      "Relay token calibration mechanism (feature flag)";
    entry ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
      "Spawn cache policy: off or safe_only";
  ]

let keeper_entries =
  [
    entry ~default:"true" "MASC_KEEPER_BOOTSTRAP_ENABLED"
      "Enable keeper auto-bootstrap";
    entry ~default:"10000" "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
      "Max concurrent active keepers";
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
    entry ~default:"(none)" "MASC_STRUCTURED_STATE"
      "Enable structured JSON state in checkpoints";
    entry ~default:"(none)" "MASC_TLA_TRACE"
      "Enable TLA+ trace emission";
  ]

let keeper_execution_entries =
  [
    entry ~default:"0.5" "MASC_KEEPER_COMPACT_RATIO"
      "Context compaction trigger ratio";
    entry ~default:"12" "MASC_KEEPER_COMPACT_MAX_MESSAGES"
      "Max messages before compaction";
    entry ~default:"4000" "MASC_KEEPER_COMPACT_MAX_TOKENS"
      "Max tokens before compaction (0=disabled)";
    entry ~default:"0.10" "MASC_KEEPER_COST_GATE_USD"
      "Legacy keeper cost gate (unused by unified turn cost guard)";
    entry ~default:"0" "MASC_KEEPER_TOOL_COST_MAX_USD"
      "Unified turn accumulated cost ceiling (USD, 0=disabled)";
    entry ~default:"0.4" "MASC_KEEPER_UNIFIED_TEMP" "Unified turn temperature";
    entry ~default:"131072" "MASC_KEEPER_UNIFIED_MAX_TOKENS"
      "Unified turn max output tokens";
    entry ~default:"20" "MASC_KEEPER_UNIFIED_MAX_TURNS"
      "Unified turn max tool loops";
    entry ~default:"3" "MASC_KEEPER_MAX_TOOL_ROUNDS"
      "Max tool loop rounds per turn";
    entry ~default:"4000" "MASC_KEEPER_AUTONOMOUS_MAX_TOKENS"
      "Autonomous execution max tokens";
    entry ~default:"0.55" "MASC_KEEPER_PROACTIVE_TEMP_LOW"
      "Proactive temperature (low urgency)";
    entry ~default:"0.75" "MASC_KEEPER_PROACTIVE_TEMP_MID"
      "Proactive temperature (mid urgency)";
    entry ~default:"0.9" "MASC_KEEPER_PROACTIVE_TEMP_HIGH"
      "Proactive temperature (high urgency)";
    entry ~default:"0.72" "MASC_KEEPER_PROACTIVE_SIMILARITY"
      "Proactive similarity threshold";
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
    entry ~default:"false" "MASC_COMMAND_PLANE_SNAPSHOT_REFRESH_ENABLED"
      "Enable proactive command-plane snapshot refresh loop";
    entry ~default:"30" "MASC_COMMAND_PLANE_SNAPSHOT_CACHE_TTL_S"
      "TTL for on-demand command-plane snapshot cache hits";
    entry ~default:"(none)" "MASC_DASHBOARD_CACHE_MAX_ENTRIES"
      "Dashboard cache max entries (clamped 16-512)";
    entry ~default:"0.50" "MASC_DASHBOARD_CTX_COMPACTING"
      "Context ratio threshold: compacting";
    entry ~default:"0.85" "MASC_DASHBOARD_CTX_HANDOFF_IMMINENT"
      "Context ratio threshold: handoff-imminent";
    entry ~default:"0.70" "MASC_DASHBOARD_CTX_PREPARING"
      "Context ratio threshold: preparing";
    entry ~default:"75" "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      "Execution refresh timeout";
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
    entry ~default:"0.95" "MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO"
      "Runtime warning context ratio threshold";
    entry ~default:"300.0" "MASC_DASHBOARD_SIGNAL_LIVE_SEC"
      "Duration for signal to count as live (seconds, 5 min)";
    entry ~default:"600.0" "MASC_DASHBOARD_SIGNAL_QUIET_SEC"
      "Duration for borderline quiet warning (seconds, 10 min)";
    entry ~default:"1200.0" "MASC_DASHBOARD_SIGNAL_STALE_SEC"
      "Duration after which a signal is stale (seconds, 20 min)";
    entry ~default:"8" "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      "Transport health timeout";
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
    entry ~default:"(none)" "MASC_CHANNEL_GATE_DEDUP_MAX_ENTRIES"
      "Dedup table max entries (clamped 100-100000)";
    entry ~default:"(none)" "MASC_CHANNEL_GATE_DEDUP_TTL_SEC"
      "Dedup TTL (seconds, clamped 10-3600)";
    entry ~default:"(none)" "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH"
      "Max content length (clamped 100-16000)";
    entry ~default:"(none)" "MASC_CHANNEL_GATE_SLOW_MS"
      "Slow threshold in ms (clamped 250-120000)";
    entry ~default:"30" "MASC_DISCORD_STATUS_STALE_SEC"
      "Discord status stale threshold (seconds)";
    entry ~default:"30" "MASC_IMESSAGE_STATUS_STALE_SEC"
      "iMessage status stale threshold (seconds)";
  ]

let circuit_breaker_entries =
  [
    entry ~default:"(none)" "MASC_CIRCUIT_COOLDOWN"
      "Cooldown before half-open retry (seconds)";
    entry ~default:"(none)" "MASC_CIRCUIT_FAILURE_WINDOW_SEC"
      "Failure counting window (seconds)";
    entry ~default:"(none)" "MASC_CIRCUIT_THRESHOLD"
      "Failure threshold before circuit opens";
  ]

let cli_entries =
  [
    entry ~default:"auto" "MASC_CLI_AGENT"
      "CLI default agent name";
  ]

let compaction_entries =
  [
    entry ~default:"0.95" "MASC_COMPACT_ANCHOR_BOOST"
      "Anchor boost for important messages in compaction";
    entry ~default:"0.3" "MASC_COMPACT_DROP_THRESHOLD"
      "Drop importance threshold for compaction";
    entry ~default:"0.70" "MASC_COMPACT_DYN_FOCUSED_RATIO"
      "Dynamic compaction ratio for focused sessions";
    entry ~default:"0.80" "MASC_COMPACT_DYN_MULTI_AGENT_RATIO"
      "Dynamic compaction ratio for multi-agent sessions";
    entry ~default:"5" "MASC_COMPACT_KEEP_RECENT"
      "Number of recent messages to always keep in compaction";
    entry ~default:"(none)" "MASC_COMPACT_LARGE_CLOUD_FLOOR"
      "Large cloud context floor for compaction (tokens)";
    entry ~default:"0.4" "MASC_COMPACT_ROLE_ASSISTANT"
      "Compaction importance score for assistant role";
    entry ~default:"1.0" "MASC_COMPACT_ROLE_SYSTEM"
      "Compaction importance score for system role";
    entry ~default:"0.7" "MASC_COMPACT_ROLE_TOOL"
      "Compaction importance score for tool role";
    entry ~default:"0.6" "MASC_COMPACT_ROLE_USER"
      "Compaction importance score for user role";
    entry ~default:"(none)" "MASC_COMPACT_SMALL_LOCAL_FLOOR"
      "Small local context floor for compaction (tokens)";
    entry ~default:"0.5" "MASC_COMPACT_TOOL_ABSENT"
      "Compaction score when tool output absent";
    entry ~default:"0.8" "MASC_COMPACT_TOOL_PRESENT"
      "Compaction score when tool output present";
    entry ~default:"1500" "MASC_COMPACT_TOOL_PRUNE_LIMIT"
      "Tool output prune character limit";
    entry ~default:"0.50" "MASC_COMPACT_W_RECENCY"
      "Weight for recency in compaction scoring";
    entry ~default:"0.35" "MASC_COMPACT_W_ROLE"
      "Weight for role in compaction scoring";
    entry ~default:"0.15" "MASC_COMPACT_W_TOOL"
      "Weight for tool in compaction scoring";
    entry ~default:"0.95" "MASC_CONTEXT_RATIO_HARD_CAP"
      "Absolute ceiling for compaction ratio_gate (clamped 0.80-0.99)";
  ]

let control_plane_entries =
  [
    entry ~default:"14" "MASC_CP_CLEANUP_DAYS"
      "Days before dead/stale CP data is eligible for cleanup";
    entry ~default:"(none)" "MASC_CP_SUMMARY_REFRESH_DISABLED"
      "Disable CP summary refresh loop (1=disabled)";
  ]

let decision_entries =
  [
    entry ~default:"50" "MASC_DECISION_AUDIT_RING_CAPACITY"
      "Decision audit ring buffer capacity";
    entry ~default:"0" "MASC_DECISION_LAYER_LEVEL"
      "Decision layer level (0=off, 1=audit, 2+=extended)";
    entry ~default:"3600.0" "MASC_DECISION_TTL_SEC"
      "Default TTL for pending decisions (seconds, 1 hour)";
  ]

let docker_playground_entries =
  [
    entry ~default:"keeper-playground" "MASC_KEEPER_DOCKER_CONTAINER"
      "Docker container name for keeper playground";
    entry ~default:"(none)" "MASC_KEEPER_DOCKER_PLAYGROUND"
      "Route keeper_bash through Docker container (feature flag)";
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
    entry ~default:"true" "MASC_ECONOMY_REPUTATION_MULTIPLIER"
      "Enable reputation multiplier";
    entry ~default:"1.0" "MASC_ECONOMY_REWARD_BOARD_POST"
      "Reward for a board post";
    entry ~default:"0.5" "MASC_ECONOMY_REWARD_MENTION_RESPONSE"
      "Reward for responding to a mention";
    entry ~default:"10.0" "MASC_ECONOMY_REWARD_TASK_DONE"
      "Reward for completing a task";
    entry ~default:"0.5" "MASC_ECONOMY_REWARD_UPVOTE"
      "Reward for receiving an upvote";
  ]

let file_lock_entries =
  [
    entry ~default:"(none)" "MASC_FILE_LOCK_MAX_ENTRIES"
      "Maximum concurrent lock entries (clamped 64-4096)";
    entry ~default:"(none)" "MASC_FILE_LOCK_STALE_SEC"
      "Stale lock entry timeout (seconds, clamped 60-7200)";
  ]

let internal_timer_entries =
  [
    entry ~default:"300.0" "MASC_BRIEFING_CACHE_TTL_SEC"
      "Mission briefing cache TTL (seconds, 5 min)";
    entry ~default:"300.0" "MASC_CANCELLATION_CLEANUP_SEC"
      "Cancellation token cleanup interval (seconds)";
    entry ~default:"300.0" "MASC_KEEPER_BOOTSTRAP_WINDOW_SEC"
      "Keeper world observation bootstrap window (seconds, 5 min)";
    entry ~default:"300.0" "MASC_LABEL_QUIET_THRESHOLD_SEC"
      "Dashboard label quiet threshold (seconds, 5 min)";
    entry ~default:"900.0" "MASC_LABEL_STUCK_THRESHOLD_SEC"
      "Dashboard label stuck threshold (seconds, 15 min)";
    entry ~default:"300.0" "MASC_METRICS_FLUSH_SEC"
      "Tool metrics flush interval (seconds, 5 min)";
    entry ~default:"3600.0" "MASC_PROVIDER_RUN_TTL_SEC"
      "Provider run finished TTL (seconds, 1 hour)";
    entry ~default:"300.0" "MASC_SESSION_LIVE_TURN_WINDOW_SEC"
      "Team session live turn window (seconds, 5 min)";
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

let keeper_board_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_BOARD_LIST_CACHE_TTL_S"
      "Keeper board list cache TTL (seconds, floor 0)";
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

let keeper_cascade_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST"
      "Comma-separated provider allowlist for cascade (None=unfiltered)";
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
    entry ~default:"180.0" "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"
      "Max wait in admission queue before abandoning OAS attempt (clamped 5-1200)";
    entry ~default:"(none)" "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"
      "Max concurrent autonomous keeper turns (clamped 1-8)";
    entry ~default:"30.0" "MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC"
      "Max wait for local keeper turn gate for autonomous cycles (clamped 5-300)";
    entry ~default:"60.0" "MASC_KEEPER_BOARD_DEBOUNCE_SEC"
      "Board-reactive wakeup debounce (seconds, clamped 5-300)";
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
    entry ~default:"15" "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"
      "Max turns per single OAS Agent.run call (clamped 1-50)";
    entry ~default:"(none)" "MASC_KEEPER_OAS_TIMEOUT_SEC"
      "Per-call timeout for OAS Agent.run (adaptive when unset; clamped 30-turn_timeout)";
    entry ~default:"2.0" "MASC_KEEPER_SLEEP_CHUNK_SEC"
      "Interruptible sleep chunk size (seconds, clamped 0.1-10)";
    entry ~default:"(none)" "MASC_KEEPER_SMART_HEARTBEAT"
      "Adaptive heartbeat scheduling in keepalive loop (feature flag)";
    entry ~default:"1200.0" "MASC_KEEPER_TURN_TIMEOUT_SEC"
      "Wall-clock timeout for a single unified turn (clamped 60-3600 seconds)";
    entry ~default:"(none)" "MASC_KEEPER_WORK_AS_HEARTBEAT"
      "Successful room heartbeat after turn counts as presence proof (feature flag)";
  ]

let keeper_metrics_entries =
  [
    entry ~default:"(none)" "MASC_KEEPER_METRICS_MAX_BYTES"
      "Max metrics file size before rotation (10MB)";
    entry ~default:"1" "MASC_KEEPER_METRICS_MAX_ROTATED"
      "Number of rotated files to keep";
  ]

let keeper_proactive_entries =
  [
    entry ~default:"3" "MASC_KEEPER_PROACTIVE_MAX_ATTEMPTS"
      "Max proactive generation attempts (clamped 1-10)";
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
    entry ~default:"(none)" "MASC_KEEPER_LLM_RERANK_CASCADE"
      "Named cascade profile for LLM reranker";
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
    entry ~default:"32768" "MASC_LLAMA_MAX_TOKENS"
      "Upper bound for local runtime requests (fallback)";
    entry ~default:"0" "MASC_LOCAL_MAX_TOKENS"
      "Upper bound for local runtime requests (primary; falls back to MASC_LLAMA_MAX_TOKENS)";
    entry ~default:"(none)" "MASC_MCP_URL"
      "MASC MCP endpoint URL";
  ]

let lock_entries =
  [
    entry ~default:"300.0" "MASC_LOCK_EXPIRY_WARNING_SEC"
      "Lock expiry warning threshold (seconds before expiry)";
    entry ~default:"1800.0" "MASC_LOCK_TIMEOUT_SEC"
      "Default lock timeout (seconds, 30 min)";
  ]

let memory_entries =
  [
    entry ~default:"5" "MASC_MEMORY_OAS_DEFAULT_IMPORTANCE"
      "Default importance for OAS-stored memories (clamped 1-10)";
  ]

let message_gc_entries =
  [
    entry ~default:"200" "MASC_MESSAGE_MAX_COUNT"
      "Maximum message files retained per room";
  ]

let model_routing_entries =
  [
    entry ~default:"(none)" "MASC_DEFAULT_CASCADE"
      "Default cascade label; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_MODEL"
      "Default model id; None when unset";
    entry ~default:"(none)" "MASC_DEFAULT_PROVIDER"
      "Default provider name; None when unset";
    entry ~default:"task" "MASC_GOAL_DISPATCH_RUNTIME"
      "Goal dispatch runtime type";
    entry ~default:"(none)" "MASC_GOAL_MODELS"
      "Goal models comma-separated; None when unset";
    entry ~default:"(none)" "MASC_ROUTING_CASCADE"
      "Routing cascade for team session routing";
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
    entry ~default:"60" "MASC_OPERATOR_JUDGE_ROOM_TTL_SEC"
      "Room TTL for operator judge cleanup (clamped >=15 seconds)";
    entry ~default:"300" "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC"
      "Session TTL for operator judge cleanup (clamped >=30 seconds)";
    entry ~default:"(none)" "MASC_OPERATOR_JUDGE_TIMEOUT_SEC"
      "Background operator judge timeout (falls back to inference timeout)";
  ]

let orchestrator_entries =
  [
    entry ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"
      "Orchestrator agent name";
    entry ~default:"(none)" "MASC_ORCHESTRATOR_ENABLED"
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
    entry ~default:"false" "MASC_ALLOW_REPO_CONFIG_FALLBACK"
      "Allow repo config fallback resolution";
    entry ~default:"(none)" "MASC_ASSETS_DIR"
      "Assets directory override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_INPUT"
      "Base path input override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_RESOLUTION_SOURCE"
      "Base path resolution source override; None when unset";
    entry ~default:"(none)" "MASC_BASE_PATH_STRICT"
      "Fail-fast on base path resolution issues";
    entry ~default:"(none)" "MASC_CONFIG_DIR"
      "Config directory override; None when unset";
    entry ~default:"(none)" "MASC_DATA_DIR"
      "Data directory override; None=<base_path>/data";
    entry ~default:"(none)" "MASC_PERSONAS_DIR"
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

let relay_entries =
  [
    entry ~default:"auto" "MASC_RELAY_TARGET_AGENT"
      "Relay target agent name";
  ]

let session_entries =
  [
    entry ~default:"3600.0" "MASC_SESSION_MAX_AGE_SEC"
      "Maximum session age before cleanup (seconds, 1 hour)";
    entry ~default:"60.0" "MASC_SESSION_RATE_LIMIT_WINDOW_SEC"
      "Rate limit window (seconds)";
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

let spawn_entries =
  [
    entry ~default:"7200.0" "MASC_SPAWN_CODING_TIMEOUT_SEC"
      "Extended timeout for coding mode (seconds, 2 hours)";
    entry ~default:"60.0" "MASC_SPAWN_GRACE_PERIOD_SEC"
      "Grace period before timeout for SIGTERM checkpoint (seconds)";
    entry ~default:"600.0" "MASC_SPAWN_TIMEOUT_SEC"
      "Default spawn timeout for agent processes (seconds)";
  ]

let sse_entries =
  [
    entry ~default:"(none)" "MASC_SSE_STREAM_CAPACITY"
      "Per-client SSE event stream capacity (clamped 8-1024)";
  ]

let swarm_entries =
  [
    entry ~default:"(none)" "MASC_SWARM_MOVING_WINDOW_SEC"
      "Moving window for swarm activity detection (seconds, floor 30)";
  ]

let task_entries =
  [
    entry ~default:"3600.0" "MASC_CLAIM_TTL_SECONDS"
      "Maximum time a task stays claimed without heartbeat before auto-release (seconds)";
  ]

let team_session_entries =
  [
    entry ~default:"0.72" "MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD"
      "Router judge confidence threshold (clamped 0-1)";
    entry ~default:"(none)" "MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL"
      "Router judge model override; None when unset";
    entry ~default:"15" "MASC_TEAM_SESSION_ROUTER_JUDGE_TIMEOUT_SEC"
      "Team session router judge timeout (clamped >=5 seconds)";
  ]

let telemetry_entries =
  [
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
    entry ~default:"false" "MASC_TEST_ALLOW_INHERITED_BASE_PATH"
      "Allow inherited base path in test environments";
  ]

let timeout_entries =
  [
    entry ~default:"300" "MASC_A2A_DELEGATION_TIMEOUT_SEC"
      "A2A task delegation timeout (seconds)";
    entry ~default:"100" "MASC_EVENT_BUFFER_SIZE"
      "A2A event buffer size per subscription";
    entry ~default:"30.0" "MASC_SSE_KEEPALIVE_SEC"
      "SSE keepalive interval (seconds, floor 1)";
    entry ~default:"15.0" "MASC_TIMEOUT_GCLOUD_AUTH_SEC"
      "gcloud auth token fetch timeout (seconds)";
  ]

let tool_entries =
  [
    entry ~default:"(none)" "MASC_FULL_SURFACE"
      "Include hidden/developer tools in tool list (feature flag)";
    entry ~default:"512" "MASC_LIST_PAGE_SIZE"
      "Tool list page size (clamped 10-1024)";
    entry ~default:"(none)" "MASC_MAX_WRITE_SIZE_BYTES"
      "Maximum write size in bytes (1MB)";
    entry ~default:"(none)" "MASC_PLACEHOLDER_TOOLS_ENABLED"
      "Enable placeholder tool exposure";
    entry ~default:"(none)" "MASC_PUBLIC_TOOLS_EXTRA"
      "Extra public tools (comma-separated names); None when unset";
    entry ~default:"(none)" "MASC_TOOL_DESCRIPTION_BUDGET"
      "Tool description budget max chars; None=unlimited";
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
      (server_entries @ path_entries @ control_plane_entries
       @ docker_playground_entries @ test_entries);
    category "auth" auth_entries;
    category "transport" transport_entries;
    category "storage" (storage_entries @ cache_entries @ memory_entries @ board_entries);
    category "runtime"
      (runtime_entries @ cli_entries @ relay_entries @ task_entries
       @ message_gc_entries @ pulse_entries @ internal_timer_entries
       @ timeout_entries @ sse_entries @ swarm_entries @ telemetry_entries
       @ circuit_breaker_entries @ tool_entries);
    category "rate_limiting" rate_limiting_entries;
    category "inference"
      (inference_entries @ model_routing_entries @ oas_sse_entries
       @ local_runtime_entries);
    category "keeper"
      (keeper_entries @ keeper_alert_entries @ keeper_bootstrap_entries
       @ keeper_keepalive_entries @ keeper_metrics_entries
       @ keeper_board_entries);
    category "keeper_execution"
      (keeper_execution_entries @ compaction_entries @ decision_entries
       @ keeper_tool_entries @ keeper_cascade_entries
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
      (shutdown_entries @ spawn_entries @ file_lock_entries
       @ cancellation_entries @ zombie_cleanup_entries @ lock_entries
       @ procedural_memory_entries);
    category "worker" (worker_entries @ worker_runtime_entries);
    category "web_search" web_search_entries;
    category "session" (session_entries @ team_session_entries @ tempo_entries);
  ]

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
