(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    {!local_llm_default_url} follows the same env override chain that
    OAS discovery uses before falling back to the current local runtime
    URL.

    @since 2.241.0 *)

(** {1 Ollama defaults} *)

(** Default port for Ollama (OpenAI-compatible at [/v1]). *)
val ollama_default_port : int

(** ["http://127.0.0.1:<ollama_default_port>"]. *)
val ollama_default_url : string

(** [":<ollama_default_port>"] — substring used by Ollama URL
    heuristics. Anchored to {!ollama_default_port} so a port change
    updates every classifier in one place. *)
val ollama_port_needle : string

(** Ollama native API path for the running-models ("process status")
    endpoint. Used by {!Cascade_ollama_probe} and
    {!Tool_local_runtime_probe}. *)
val ollama_api_ps_path : string

(** Ollama native API path for text generation. Used by the tool-level
    probe path that exercises a model end-to-end. *)
val ollama_api_generate_path : string

(** Permissive substring check against {!ollama_port_needle}. Works
    for [http://], [https://], [127.0.0.1], [localhost], or bare
    [host:port]. *)
val is_ollama_url : string -> bool

(** {1 OpenAI-compatible API paths} *)

(** [/v1/chat/completions]. *)
val openai_chat_completions_path : string

(** [/v1/models]. *)
val openai_models_path : string

(** {1 CLI sentinel transport} *)

(** ["cli:"] — prefix marking a CLI-backed transport (e.g.
    [cli:codex]). *)
val cli_sentinel_prefix : string

(** Strict prefix match for {!cli_sentinel_prefix}. *)
val is_cli_sentinel_url : string -> bool

(** {1 Local LLM URL} *)

(** Override order:
    [OAS_LOCAL_LLM_URL] → [OAS_LOCAL_QWEN_URL] → {!ollama_default_url}. *)
val local_llm_default_url : string

(** {1 MASC HTTP server} *)

val masc_http_default_port : int

(** String form of {!masc_http_default_port} for env-config fallback. *)
val masc_http_default_port_s : string

val masc_http_default_host : string

(** {1 Loopback detection} *)

(** Treats ["localhost"] (case-insensitive, trimmed) and any IPv4/IPv6
    loopback literal as loopback. Unlike a prefix match, malformed
    addresses return [false] (so ["127.invalid"] is rejected). *)
val is_loopback_host : string -> bool

(** Convenience for [Uri.host]-style inputs. [None] → [false]. *)
val is_loopback_host_opt : string option -> bool

(** {1 Vite dev frontend} *)

val vite_dev_default_port : int

(** Ordered [127.0.0.1 → localhost → [::1]] on {!vite_dev_default_port};
    matches the historical CORS allowlist. *)
val vite_dev_default_origins : string list

(** {1 SearXNG & OpenTelemetry} *)

val searxng_default_port : int

val searxng_default_url : string

val otel_default_port : int

val otel_default_url : string

(** {1 CORS / DNS rebinding allowlist} *)

(** Allowed origins read by [server_routes_http_common.ml]. Update
    here to add/remove CORS origins. *)
val allowed_origins : string list
