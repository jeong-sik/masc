(** Server, transport, and storage environment configuration.

    Centralizes MASC_GRPC_*, MASC_WS_*, MASC_STORAGE_*, and related
    server-level env vars.

    {b NOTE}: This module has zero callers as of v2.162.0.
    All production code reads from [Env_config_runtime] and other
    domain-specific config modules. This module is retained for
    backward compatibility but should not be used for new code.
    See [Feature_flag_registry] for the canonical flag defaults. *)

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
  (** "true"/"1" → h2_only, "false"/"0" → h1_only, "auto"/unset → auto *)
  let mode =
    match Sys.getenv_opt "MASC_USE_H2" |> trim_opt with
    | Some raw -> (
        match String.lowercase_ascii raw with
        | "1" | "true" -> "h2_only"
        | "0" | "false" -> "h1_only"
        | _ -> "auto")
    | None -> "auto"
end

(** {1 WebRTC Transport} *)

module Webrtc = struct
  let enabled =
    get_bool ~default:true "MASC_WEBRTC_ENABLED"

  let ice_servers_json_opt () =
    Sys.getenv_opt "MASC_WEBRTC_ICE_SERVERS_JSON" |> trim_opt

  let ice_urls_opt () =
    Sys.getenv_opt "MASC_WEBRTC_ICE_URLS" |> trim_opt

  let ice_username_opt () =
    Sys.getenv_opt "MASC_WEBRTC_ICE_USERNAME" |> trim_opt

  let ice_credential_opt () =
    Sys.getenv_opt "MASC_WEBRTC_ICE_CREDENTIAL" |> trim_opt

  let ice_tls_ca_opt () =
    Sys.getenv_opt "MASC_WEBRTC_ICE_TLS_CA" |> trim_opt
end

(** {1 Auth & Tools} *)

module Auth = struct
  let http_auth_strict =
    get_bool ~default:false "MASC_HTTP_AUTH_STRICT"

  let admin_token_opt () =
    Sys.getenv_opt "MASC_ADMIN_TOKEN" |> trim_opt

  let tool_auth_strict =
    get_bool ~default:true "MASC_TOOL_AUTH_STRICT"
end

module Tools = struct
  let timeout_default_sec =
    max 5 (min 600 (get_int ~default:30 "MASC_TOOL_TIMEOUT_DEFAULT_SEC"))

  let readonly_retry_limit =
    min 5 (max 1 (get_int ~default:2 "MASC_TOOL_READONLY_RETRY_LIMIT"))

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
    get_string ~default:"" "MASC_STORAGE_TYPE"

  let pg_pool_size =
    max 1 (min 50 (get_int ~default:10 "MASC_PG_POOL_SIZE"))

  let base_path_opt () =
    Sys.getenv_opt "MASC_BASE_PATH" |> trim_opt
end

(** {1 Server Runtime} *)

module Runtime = struct
  let startup_watchdog_sec =
    Float.max 30.0 (Float.min 600.0 (get_float ~default:240.0 "MASC_STARTUP_WATCHDOG_SEC"))

  let telemetry_enabled =
    get_bool ~default:true "MASC_TELEMETRY_ENABLED"

  let openai_compat =
    get_bool ~default:false "MASC_OPENAI_COMPAT"

  let dispatch_v2 =
    get_bool ~default:true "MASC_DISPATCH_V2"

  let auto_respond_raw =
    get_string ~default:"" "MASC_AUTO_RESPOND"

  let parse_warn =
    get_bool ~default:false "MASC_PARSE_WARN"

  let governance_level =
    String.lowercase_ascii (get_string ~default:"production" "MASC_GOVERNANCE_LEVEL")
end

(** {1 Rate Limiting} *)

module Rate = struct
  let limit =
    get_float ~default:100.0 "MASC_RATE_LIMIT"

  let burst =
    get_int ~default:150 "MASC_RATE_BURST"
end

(** {1 Agent Identity} *)

module Agent = struct
  let transport =
    get_string ~default:"http" "MASC_AGENT_TRANSPORT"

  let name_opt () =
    Sys.getenv_opt "MASC_AGENT_NAME" |> trim_opt

  let orchestrator_agent =
    get_string ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"
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

