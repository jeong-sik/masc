(** RFC-0041 — Endpoint as the only provider abstraction.

    Replaces [Provider_adapter] entirely after migration completes (PR-D, PR-E).
    During PR-A both modules coexist; this module has zero callers in lib/ —
    it is inert infrastructure that PR-B will start consuming.

    The 6 wire-level axes ([transport], [auth], [body_schema], [stream_format],
    [capabilities], [discovery]) decompose what [Provider_adapter] expressed
    via [runtime_kind] + [auth_mode] + [tool_policy] + name-based dispatch.
    The decomposition is required to express genuine wire-level hybrids — most
    notably Kimi API which uses Anthropic body shape with OpenAI-style Bearer
    auth (see [Endpoint.kimi_api] in the registry).

    See [docs/rfc/RFC-0041-endpoint-as-only-abstraction.md] for the full design. *)

type transport =
  | Http of { base_url : string; request_path : string }
  | Cli_subprocess of { binary : string; spawn_key : string }

type auth =
  | None_required
  | Bearer of { env_var : string }
  | X_api_key of { env_var : string; version_header : (string * string) option }
  | Url_query_key of { env_var : string }
  | Cli_cached_login
  | Vertex_adc of { project_env_var : string; location_env_var : string }

type body_schema =
  | Anthropic_content_blocks
  | OpenAI_messages
  | OpenAI_messages_with_thinking
  | Ollama_options
  | Gemini_contents_parts
  | Cli_args_text
  | Cli_args_json

type stream_format =
  | Sse_openai_delta
  | Sse_anthropic_blocks
  | Sse_gemini_server_content
  | Ndjson_ollama
  | Cli_stdout_text
  | Cli_stdout_stream_json

type discovery_method =
  | No_discovery
  | Models_endpoint of { path : string }
  | Ps_endpoint of { path : string }

type capabilities = {
  supports_runtime_mcp_http_headers : bool;
  supports_per_call_mcp_config : bool;
  emits_usage_telemetry : bool;
}

type t = {
  label_prefix : string;
  display_name : string;
  transport : transport;
  auth : auth;
  body_schema : body_schema;
  stream_format : stream_format;
  capabilities : capabilities;
  discovery : discovery_method;
}

val direct_endpoints : t list
(** SSOT registry. 14 entries 1:1 with [Provider_adapter.direct_adapters].
    Drift-guard tests in [test/test_endpoint.ml] enforce alignment. *)

val find_by_label_prefix : string -> t option

val equal : t -> t -> bool
(** Structural equality on [label_prefix]. Two endpoints with the same prefix
    are considered the same endpoint regardless of resolved URL (which may
    differ across processes due to env var overrides). *)
