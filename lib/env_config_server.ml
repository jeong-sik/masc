(** Server, transport, and storage environment configuration.

    Centralizes MASC_GRPC_*, MASC_WS_*, MASC_STORAGE_*, and related
    server-level env vars. *)

open Env_config_core

(** {1 gRPC Transport} *)

module Grpc = struct
  let enabled =
    get_bool ~default:true "MASC_GRPC_ENABLED"

  let port =
    get_int ~default:8936 "MASC_GRPC_PORT"

  let target =
    get_string ~default:"" "MASC_GRPC_TARGET"
end

(** {1 WebSocket Transport} *)

module Ws = struct
  let enabled =
    get_bool ~default:true "MASC_WS_ENABLED"

  let port =
    get_int ~default:8937 "MASC_WS_PORT"
end

(** {1 HTTP/2 Transport} *)

module H2 = struct
  let enabled =
    get_bool ~default:false "MASC_USE_H2"
end

(** {1 WebRTC Transport} *)

module Webrtc = struct
  let enabled =
    get_bool ~default:false "MASC_WEBRTC_ENABLED"
end

(** {1 Auth & Tools} *)

module Auth = struct
  let admin_token_opt () =
    Sys.getenv_opt "MASC_ADMIN_TOKEN" |> trim_opt

  let tool_auth_strict =
    get_bool ~default:false "MASC_TOOL_AUTH_STRICT"
end

module Tools = struct
  let readonly_retry_limit =
    get_int ~default:3 "MASC_TOOL_READONLY_RETRY_LIMIT"

  let description_budget =
    get_int ~default:200 "MASC_TOOL_DESCRIPTION_BUDGET"

  let public_tools_extra =
    get_string ~default:"" "MASC_PUBLIC_TOOLS_EXTRA"

  let full_surface =
    get_bool ~default:false "MASC_FULL_SURFACE"
end

(** {1 Storage Backend} *)

module Storage = struct
  let storage_type =
    get_string ~default:"filesystem" "MASC_STORAGE_TYPE"

  let pg_pool_size =
    get_int ~default:4 "MASC_PG_POOL_SIZE"

  let base_path_opt () =
    Sys.getenv_opt "MASC_BASE_PATH" |> trim_opt

  let base_path_input_opt () =
    Sys.getenv_opt "MASC_BASE_PATH_INPUT" |> trim_opt
end

(** {1 Server Runtime} *)

module Runtime = struct
  let startup_watchdog_sec =
    get_float ~default:30.0 "MASC_STARTUP_WATCHDOG_SEC"

  let telemetry_enabled =
    get_bool ~default:false "MASC_TELEMETRY_ENABLED"

  let openai_compat =
    get_bool ~default:false "MASC_OPENAI_COMPAT"

  let dispatch_v2 =
    get_bool ~default:false "MASC_DISPATCH_V2"

  let auto_respond =
    get_bool ~default:false "MASC_AUTO_RESPOND"

  let parse_warn =
    get_bool ~default:false "MASC_PARSE_WARN"

  let governance_level =
    get_string ~default:"standard" "MASC_GOVERNANCE_LEVEL"
end

(** {1 Rate Limiting} *)

module Rate = struct
  let limit =
    get_int ~default:100 "MASC_RATE_LIMIT"

  let burst =
    get_int ~default:20 "MASC_RATE_BURST"
end

(** {1 Agent Identity} *)

module Agent = struct
  let transport =
    get_string ~default:"http" "MASC_AGENT_TRANSPORT"

  let name_opt () =
    Sys.getenv_opt "MASC_AGENT_NAME" |> trim_opt
end

(** {1 Config & Personas Directories} *)

module Dirs = struct
  let config_dir_opt () =
    Sys.getenv_opt "MASC_CONFIG_DIR" |> trim_opt

  let personas_dir_opt () =
    Sys.getenv_opt "MASC_PERSONAS_DIR" |> trim_opt
end

(** {1 External Services} *)

module External = struct
  let graphql_url () =
    match Sys.getenv_opt "GRAPHQL_URL" |> trim_opt with
    | Some url -> url
    | None ->
        get_string ~default:"https://second-brain-graphql-production.up.railway.app/graphql"
          "RAILWAY_GRAPHQL_URL"

  let graphql_api_key_opt () =
    Sys.getenv_opt "GRAPHQL_API_KEY" |> trim_opt

  let neo4j_uri_opt () =
    Sys.getenv_opt "NEO4J_URI" |> trim_opt

  let neo4j_http_uri_opt () =
    Sys.getenv_opt "NEO4J_HTTP_URI" |> trim_opt

  let neo4j_user () =
    get_string ~default:"neo4j" "NEO4J_USER"

  let neo4j_password_opt () =
    Sys.getenv_opt "NEO4J_PASSWORD" |> trim_opt

  let gemini_api_key_opt () =
    Sys.getenv_opt "GEMINI_API_KEY" |> trim_opt
end

(** {1 Miscellaneous} *)

module Misc = struct
  let board_backend =
    get_string ~default:"filesystem" "MASC_BOARD_BACKEND"

  let board_flush_interval_sec =
    get_float ~default:10.0 "MASC_BOARD_FLUSH_INTERVAL_SEC"

  let circuit_threshold =
    get_int ~default:5 "MASC_CIRCUIT_THRESHOLD"

  let circuit_cooldown =
    get_float ~default:60.0 "MASC_CIRCUIT_COOLDOWN"

  let pulse_max_consumer_failures =
    get_int ~default:3 "MASC_PULSE_MAX_CONSUMER_FAILURES"

  let pubsub_max_messages =
    get_int ~default:1000 "MASC_PUBSUB_MAX_MESSAGES"

  let build_git_commit () =
    get_string ~default:"unknown" "MASC_BUILD_GIT_COMMIT"

  let mcp_url_opt () =
    Sys.getenv_opt "MASC_MCP_URL" |> trim_opt

  let oas_sse_drain_interval_sec =
    get_float ~default:5.0 "MASC_OAS_SSE_DRAIN_INTERVAL_SEC"
end
