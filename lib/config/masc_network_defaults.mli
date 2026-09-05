(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    {!local_llm_default_url} follows the same env override chain that
    AGENT_CORE discovery uses before falling back to the current local runtime
    URL.

    @since 2.241.0 *)

(** {1 Ollama defaults} *)

(** Default port for Ollama (OpenAI-compatible at [/v1]). *)
val trim_trailing_slashes : string -> string
(** Strip every trailing ['/'] from a URL-shaped value.  [""] and ["/"]
    both become [""].  Paths keep their root: use
    {!Env_config_core.strip_path_trailing_slashes} for those. *)

(** ["http://127.0.0.1:<ollama_default_port>"]. *)
val ollama_default_url : string

(** Ollama native API path for the running-models ("process status")
    endpoint. Used by {!Runtime_http_probe} and
    {!Tool_local_runtime_probe}. *)
val ollama_api_ps_path : string

(** Ollama native API path for text generation. Used by the tool-level
    probe path that exercises a model end-to-end. *)
val ollama_api_generate_path : string


(** {1 OpenAI-compatible API paths} *)

(** [/v1/chat/completions]. *)
val openai_chat_completions_path : string

(** [/chat/completions] — version-free path for [Provider_config.t] where
    [base_url] already includes the version segment.  Matches the AGENT_CORE
    Agent Core's internal default in [api_openai.ml]. *)
val chat_completions_path : string

(** {1 CLI transport discriminator} *)


(** {1 Local LLM URL} *)

(** Override order:
    [AGENT_CORE_LOCAL_LLM_URL] -> {!ollama_default_url}. *)
val local_llm_default_url : string

(** {1 MASC HTTP server} *)

val masc_http_default_port : int

(** String form of {!masc_http_default_port} for env-config fallback. *)
val masc_http_default_port_s : string

val masc_http_default_host : string
(** Where the MASC HTTP server binds by default. *)

val masc_http_loopback_peer : string
(** What a client on this machine dials to reach that server.

    The same string as {!masc_http_default_host} today, and a different
    question. A bind address may be a wildcard -- {!is_unspecified_host}
    exists because 0.0.0.0 and :: mean "every interface" rather than a
    reachable peer -- so a client that reads the server's bind setting as its
    destination can end up dialing an address that is not one. *)

val masc_http_default_max_connections : int
(** Default concurrent-connection ceiling for the MASC HTTP server.

    Named here so the reader ({!Http_server_eio}) and the operator snapshot
    ({!Env_config_snapshot}) can share one number. They restated it
    independently until #14143 raised the reader to 512 and left the snapshot
    on 128. *)

(** String form of {!masc_http_default_max_connections} for the env snapshot. *)
val masc_http_default_max_connections_s : string

(** {1 Loopback detection} *)

(** Treats ["localhost"] (case-insensitive, trimmed) and any IPv4/IPv6
    loopback literal as loopback. Unlike a prefix match, malformed
    addresses return [false] (so ["127.invalid"] is rejected). *)
val is_loopback_host : string -> bool

(** Convenience for [Uri.host]-style inputs. [None] → [false]. *)
val is_loopback_host_opt : string option -> bool

val is_unspecified_host : string -> bool
(** [true] for the wildcard bind addresses 0.0.0.0 and ::. A wildcard means
    "every interface", so it is not a peer any caller can reach back on. *)

val normalize_advertised_host : string -> string
(** Turn a host that may have been written as a bind setting into one a
    client can dial.

    | Input | Result |
    |---|---|
    | [0.0.0.0], [::] | {!masc_http_default_host} |
    | ["localhost"] (any case), [::1] | {!masc_http_default_host} |
    | [127.0.1.1] and the rest of 127.0.0.0/8 | unchanged |
    | anything else | unchanged, trimmed |

    The third row is the one to read twice: this is narrower than
    {!is_loopback_host}, which accepts the whole /8. An operator who writes
    127.0.1.1 named one interface and keeps it. A change that widens this
    has to edit the table above, which is the point of writing it down. *)

val voice_audio_path_prefix : string
(** ["/api/v1/voice/audio/"] — the prefix of the route serving a synthesized
    voice clip.

    Two callers have to agree on it from different files:
    {!Server_routes_http_routes_voice} registers the route under this prefix,
    and {!Server_auth} lists the same prefix as publicly readable. A browser's
    [<audio>] element cannot send a bearer token, so the unguessable filename
    token is the capability. Drift in one direction breaks playback under
    strict auth; drift in the other exposes a path nobody meant to serve. *)

val voice_audio_path : string -> string
(** [voice_audio_path token] is the server-relative path for one clip:
    {!voice_audio_path_prefix} followed by [token]. Callers that hand out an
    absolute URL prepend their own base. *)

val normalize_loopback_base_url : string -> string
(** Strip trailing slashes from [base_url] and put its host through
    {!normalize_advertised_host}. Returns the input untouched when the host
    needs no rewrite, so a URL that is already dialable is not re-serialized.

    Note that {!Transport_read_model} has a function of the same name that
    always rebuilds through [Uri]. That one pairs the URL with a separate
    [host] field and the two have to agree (#29806); this one hands back a
    single URL and has no second value to keep in step. *)

(** {1 Vite dev frontend} *)

(** Ordered [127.0.0.1 → localhost → [::1]] on {!vite_dev_default_port};
    matches the historical CORS allowlist. *)
val vite_dev_default_origins : string list

(** {1 SearXNG & OpenTelemetry} *)

val searxng_default_url : string

val otel_default_port : int

val otel_default_url : string
