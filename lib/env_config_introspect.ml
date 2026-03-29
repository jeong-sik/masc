(** Env_config_introspect — serialize all MASC env config into categorized JSON.

    Used by the dashboard config endpoint to expose server configuration.
    Sensitive values (tokens, passwords, URLs with credentials) are masked.

    @since 2.158.0 *)

let mask_sensitive value =
  if String.length value <= 4 then "***"
  else
    let visible = min 4 (String.length value) in
    String.sub value 0 visible ^ "***"

let is_sensitive_name name =
  let lower = String.lowercase_ascii name in
  List.exists (fun pat ->
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
  let raw = Sys.getenv_opt e.env_name in
  let display_value =
    match raw with
    | None -> None
    | Some v when e.sensitive -> Some (mask_sensitive v)
    | Some v -> Some v
  in
  `Assoc [
    ("env", `String e.env_name);
    ("description", `String e.description);
    ("value", match display_value with Some v -> `String v | None -> `Null);
    ("default", `String e.default_display);
    ("source", `String (if raw = None then "default" else "env"));
    ("sensitive", `Bool e.sensitive);
  ]

let category name entries =
  (name, `List (List.map read_entry entries))

(* ================================================================ *)
(* Category definitions                                              *)
(* ================================================================ *)

let server_entries = [
  entry ~default:"8935" "MASC_HTTP_PORT" "HTTP server port";
  entry ~default:"127.0.0.1" "MASC_HOST" "Server bind host";
  entry ~default:"(derived)" "MASC_HTTP_BASE_URL" "Public HTTP base URL";
  entry ~default:"" "MASC_CLUSTER_NAME" "Cluster name for multi-instance";
  entry ~default:"(cwd)" "MASC_BASE_PATH" "Base storage directory";
  entry ~default:"(none)" "MASC_BUILD_GIT_COMMIT" "Build git commit hash";
]

let auth_entries = [
  entry ~sensitive:true ~default:"(none)" "MASC_ADMIN_TOKEN" "Admin authentication token";
  entry ~default:"true" "MASC_TOOL_AUTH_STRICT" "Require auth for all tool calls";
  entry ~default:"false" "MASC_HTTP_AUTH_STRICT" "Require auth for HTTP endpoints";
]

let runtime_entries = [
  entry ~default:"(auto)" "MASC_LOG_LEVEL" "Log level override";
  entry ~default:"true" "MASC_TELEMETRY_ENABLED" "Enable telemetry collection";
  entry ~default:"false" "MASC_PARSE_WARN" "Enable JSON parse warnings";
  entry ~default:"production" "MASC_GOVERNANCE_LEVEL" "Governance enforcement level";
  entry ~default:"(none)" "MASC_AUTO_RESPOND" "Auto-respond mode";
  entry ~default:"true" "MASC_DISPATCH_V2" "Enable V2 dispatch engine";
]

let rate_limiting_entries = [
  entry ~default:"100.0" "MASC_RATE_LIMIT" "Requests per second";
  entry ~default:"150" "MASC_RATE_BURST" "Burst capacity";
  entry ~default:"300.0" "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC" "Stale bucket cleanup interval (seconds)";
  entry ~default:"3600.0" "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC" "Max age for rate limit entries (seconds)";
]

let storage_entries = [
  entry ~default:"filesystem" "MASC_STORAGE_TYPE" "Backend storage type (filesystem|postgres)";
  entry ~sensitive:true ~default:"(none)" "MASC_POSTGRES_URL" "PostgreSQL connection URL";
  entry ~default:"10" "MASC_PG_POOL_SIZE" "PostgreSQL connection pool size";
  entry ~default:"1000" "MASC_PUBSUB_MAX_MESSAGES" "Max pubsub messages per batch";
]

let transport_entries = [
  entry ~default:"8936" "MASC_GRPC_PORT" "gRPC server port";
  entry ~default:"true" "MASC_GRPC_ENABLED" "Enable gRPC transport";
  entry ~default:"(derived)" "MASC_GRPC_TARGET" "gRPC client target address";
  entry ~default:"8937" "MASC_WS_PORT" "WebSocket server port";
  entry ~default:"true" "MASC_WS_ENABLED" "Enable WebSocket transport";
  entry ~default:"true" "MASC_WEBRTC_ENABLED" "Enable WebRTC transport";
  entry ~default:"auto" "MASC_USE_H2" "HTTP mode (auto|h2_only|h1_only)";
  entry ~default:"240" "MASC_STARTUP_WATCHDOG_SEC" "Startup watchdog timeout (seconds)";
  entry ~default:"(none)" "MASC_AGENT_TRANSPORT" "Agent transport preference";
  entry ~default:"false" "MASC_OPENAI_COMPAT" "Enable OpenAI-compatible endpoint";
]

let chain_entries = [
  entry ~default:"gemini" "MASC_CHAIN_JUDGE_MODEL" "Chain evaluator/judge model";
  entry ~default:"20" "MASC_CHAIN_MAX_DEPTH" "Chain max execution depth";
  entry ~default:"10" "MASC_CHAIN_MAX_CONCURRENCY" "Chain max concurrent nodes";
  entry ~default:"(derived)" "MASC_MCP_URL" "MCP endpoint URL for chain";
]

let inference_entries = [
  entry ~default:"30" "MASC_INFERENCE_TIMEOUT_SEC" "Inference call timeout (seconds)";
  entry ~default:"true" "MASC_INFERENCE_CACHE_ENABLED" "Enable inference result cache";
  entry ~default:"auto" "MASC_GLM_DEFAULT_MODEL" "Default GLM model";
  entry ~default:"auto" "MASC_GLM_FLASH_MODEL" "GLM flash model";
  entry ~default:"gemini-2.5-pro" "MASC_GEMINI_DEFAULT_MODEL" "Default Gemini model";
  entry ~default:"claude-sonnet-4-6" "MASC_CLAUDE_DEFAULT_MODEL" "Default Claude model";
  entry ~default:"gpt-4.1" "MASC_OPENAI_DEFAULT_MODEL" "Default OpenAI model";
]

let keeper_entries = [
  entry ~default:"true" "MASC_KEEPER_BOOTSTRAP_ENABLED" "Enable keeper auto-bootstrap";
  entry ~default:"3" "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE" "Max concurrent active keepers";
  entry ~default:"300" "MASC_KEEPER_SNAPSHOT_SEC" "Keeper keepalive snapshot interval";
  entry ~default:"false" "MASC_KEEPER_DEBUG" "Enable keeper debug logging";
  entry ~default:"0.10" "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" "Daily deliberation budget (USD)";
]

let dashboard_entries = [
  entry ~default:"false" "MASC_DASHBOARD_FIXTURES_ENABLED" "Enable dashboard test fixtures";
  entry ~default:"(none)" "MASC_DASHBOARD_FIXTURE" "Dashboard fixture name override";
  entry ~default:"75" "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S" "Execution refresh timeout";
  entry ~default:"8" "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S" "Transport health timeout";
]

(* ================================================================ *)
(* Main JSON builder                                                 *)
(* ================================================================ *)

let server_meta () =
  let git_commit =
    match Sys.getenv_opt "MASC_BUILD_GIT_COMMIT" with
    | Some c when String.trim c <> "" -> Some (String.trim c)
    | _ -> None
  in
  `Assoc [
    ("version", `String Version.version);
    ("git_commit", match git_commit with Some c -> `String c | None -> `Null);
    ("ocaml_version", `String Sys.ocaml_version);
    ("uptime_seconds", `Float (Server_startup_state.elapsed_since_start ()));
    ("pid", `Int (Unix.getpid ()));
  ]

let all_categories () = [
  category "server" server_entries;
  category "auth" auth_entries;
  category "transport" transport_entries;
  category "storage" storage_entries;
  category "runtime" runtime_entries;
  category "rate_limiting" rate_limiting_entries;
  category "chain" chain_entries;
  category "inference" inference_entries;
  category "keeper" keeper_entries;
  category "dashboard" dashboard_entries;
]

let to_json () =
  `Assoc [
    ("generated_at", `String (Types.now_iso ()));
    ("server", server_meta ());
    ("categories", `Assoc (all_categories ()));
  ]

(** Return config JSON filtered to a single category.
    Returns the full JSON when [cat] is [None]. *)
let to_json_filtered ?cat () =
  match cat with
  | None -> to_json ()
  | Some name ->
    let cats = all_categories () in
    let filtered =
      List.filter (fun (k, _) -> k = name) cats
    in
    `Assoc [
      ("generated_at", `String (Types.now_iso ()));
      ("server", server_meta ());
      ("categories", `Assoc filtered);
    ]
