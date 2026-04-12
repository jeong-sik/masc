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
    [ "token"; "password"; "secret"; "key"; "credential"; "postgres_url";
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
  ]

let auth_entries =
  [
    entry ~sensitive:true ~default:"(none)" "MASC_ADMIN_TOKEN"
      "Admin authentication token";
    entry ~default:"true" "MASC_TOOL_AUTH_STRICT"
      "Require auth for all tool calls";
    entry ~default:"false" "MASC_HTTP_AUTH_STRICT"
      "Require auth for HTTP endpoints";
  ]

let runtime_entries =
  [
    entry ~default:"(auto)" "MASC_LOG_LEVEL" "Log level override";
    entry ~default:"true" "MASC_TELEMETRY_ENABLED"
      "Enable telemetry collection";
    entry ~default:"false" "MASC_PARSE_WARN" "Enable JSON parse warnings";
    entry ~default:"production" "MASC_GOVERNANCE_LEVEL"
      "Governance enforcement level";
    entry ~default:"(none)" "MASC_AUTO_RESPOND" "Auto-respond mode";
    entry ~default:"true" "MASC_DISPATCH_V2" "Enable V2 dispatch engine";
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
  ]

let keeper_entries =
  [
    entry ~default:"true" "MASC_KEEPER_BOOTSTRAP_ENABLED"
      "Enable keeper auto-bootstrap";
    entry ~default:"3" "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE"
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
  ]

let keeper_execution_entries =
  [
    entry ~default:"0.5" "MASC_KEEPER_COMPACT_RATIO"
      "Context compaction trigger ratio";
    entry ~default:"12" "MASC_KEEPER_COMPACT_MAX_MESSAGES"
      "Max messages before compaction";
    entry ~default:"4000" "MASC_KEEPER_COMPACT_MAX_TOKENS"
      "Max tokens before compaction (0=disabled)";
    entry ~default:"0.10" "MASC_KEEPER_COST_GATE_USD" "Per-turn cost gate (USD)";
    entry ~default:"0.50" "MASC_KEEPER_TOOL_COST_MAX_USD"
      "Max tool call cost (USD)";
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
    entry ~default:"0.7" "MASC_AUTONOMY_THOMPSON_WEIGHT"
      "Thompson sampling weight";
    entry ~default:"0.95" "MASC_AUTONOMY_VOTE_DECAY_FACTOR"
      "Vote decay factor";
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
    entry ~default:"false" "MASC_DASHBOARD_FIXTURES_ENABLED"
      "Enable dashboard test fixtures";
    entry ~default:"false" "MASC_COMMAND_PLANE_SNAPSHOT_REFRESH_ENABLED"
      "Enable proactive command-plane snapshot refresh loop";
    entry ~default:"30" "MASC_COMMAND_PLANE_SNAPSHOT_CACHE_TTL_S"
      "TTL for on-demand command-plane snapshot cache hits";
    entry ~default:"(none)" "MASC_DASHBOARD_FIXTURE"
      "Dashboard fixture name override";
    entry ~default:"75" "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      "Execution refresh timeout";
    entry ~default:"8" "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      "Transport health timeout";
    entry ~default:"0.85" "MASC_DASHBOARD_CTX_HANDOFF_IMMINENT"
      "Context ratio threshold: handoff-imminent";
    entry ~default:"0.70" "MASC_DASHBOARD_CTX_PREPARING"
      "Context ratio threshold: preparing";
    entry ~default:"0.50" "MASC_DASHBOARD_CTX_COMPACTING"
      "Context ratio threshold: compacting";
    entry ~default:"0.9" "MASC_DASHBOARD_HEALTH_CTX_CRITICAL"
      "Health scoring: context ratio critical threshold";
    entry ~default:"0.8" "MASC_DASHBOARD_HEALTH_CTX_WARN"
      "Health scoring: context ratio warning threshold";
  ]

let all_categories () =
  [
    category "server" server_entries;
    category "auth" auth_entries;
    category "transport" transport_entries;
    category "storage" storage_entries;
    category "runtime" runtime_entries;
    category "rate_limiting" rate_limiting_entries;
    category "inference" inference_entries;
    category "keeper" keeper_entries;
    category "keeper_execution" keeper_execution_entries;
    category "keeper_guardrails" keeper_guardrail_entries;
    category "autonomy" autonomy_entries;
    category "level2" level2_entries;
    category "dashboard" dashboard_entries;
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
