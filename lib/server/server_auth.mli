(** Server Auth — HTTP token / loopback / origin enforcement and the
    [with_*_auth] handler combinators used by [bin/main_eio.ml] routes.

    Centralises the policy that determines (a) whether a request is from
    a verified internal keeper subprocess, (b) which agent name applies
    for permission gating, (c) whether an origin is loopback-dev safe,
    and (d) which CORS headers go on each response.  Every public route
    handler should run through one of the [with_*_auth] wrappers
    rather than reimplementing token / origin checks. *)

(** {1 Trim / parse helpers} *)

val trim_opt : string option -> string option
(** Trim a [string option]; collapses [Some ""] to [None]. *)

val strip_prefix : prefix:string -> string -> string
(** Remove [prefix] from [s] when present, else return [s] unchanged. *)

val strip_suffix : suffix:string -> string -> string
(** Remove [suffix] from [s] when present, else return [s] unchanged. *)

val trim_nonempty : string -> string option
(** [Some trimmed] when non-empty, else [None]. *)

val split_csv_nonempty : string -> string list
(** Comma-separated split with empty entries dropped. *)

(** {1 Bind host / loopback classification} *)

val configured_bind_host : unit -> string
(** Currently configured HTTP bind host (env / config). *)

val ipaddr_is_loopback : (Ipaddr.V4.t, Ipaddr.V6.t) Ipaddr.v4v6 -> bool
val ipaddr_is_unspecified : (Ipaddr.V4.t, Ipaddr.V6.t) Ipaddr.v4v6 -> bool
val is_loopback_host : string -> bool
val is_unspecified_host : string -> bool

val base_url_has_non_loopback_host : unit -> bool
(** [true] when the configured base URL points outside loopback;
    governs whether strict auth must be enabled. *)

val http_auth_strict_enabled : unit -> bool
(** [true] when strict HTTP token auth is enabled by config. *)

val http_auth_bind_host : unit -> string
(** Bind host used by HTTP auth checks (mirrors
    [configured_bind_host]). *)

val http_auth_bind_is_loopback : unit -> bool
(** [true] when [http_auth_bind_host] is loopback. *)

val strict_http_auth_error : string -> string
(** Render the structured error message returned when a non-loopback
    deployment is missing strict token auth. *)

val ensure_strict_http_token_auth :
  endpoint:string -> Types.auth_config -> (Types.auth_config, string) result
(** Validate [auth_config] for [endpoint]: when the endpoint is
    non-loopback it must carry a strict token configuration. *)

(** {1 Token / agent extraction from requests} *)

val bearer_token_from_header : string -> string option
(** Extract the bearer token from an [Authorization] header value. *)

val auth_token_from_request : Httpun.Request.t -> string option
(** Token from [Authorization: Bearer …] on the request. *)

val observer_sse_query_token_from_request : Httpun.Request.t -> string option
(** Observer/presence SSE allows the token via query string for browser
    EventSource. *)

val observer_sse_auth_token_from_request : Httpun.Request.t -> string option
(** Combined header-or-query lookup for the SSE observer endpoint. *)

val agent_from_request : Httpun.Request.t -> string option
(** Caller-declared agent name from the request (header / query). *)

val internal_keeper_agent_from_request : Httpun.Request.t -> string option
(** Agent name when the request is recognised as an internal keeper
    subprocess via the dedicated header. *)

val resolve_agent_name_for_auth_raw :
  base_path:string ->
  Httpun.Request.t ->
  token:string option -> (string option, Types.masc_error) result
(** Resolve the agent name to use for permission checks given the
    request and bearer [token].  [Ok None] means "no agent context". *)

(** {1 MCP / observer / operator verification} *)

val verify_mcp_auth :
  base_path:string -> Httpun.Request.t -> ('a option, string) result
(** Bearer token check for the [/mcp] endpoint. *)

val verify_mcp_observer_stream_auth :
  base_path:string -> Httpun.Request.t -> ('a option, string) result
(** Variant for the observer SSE stream (allows query token). *)

val verify_operator_mcp_auth :
  base_path:string -> Httpun.Request.t -> ('a option, string) result
(** Variant for [/mcp/operator] (admin-tier). *)

(** {1 Dashboard actor identification} *)

val request_actor_hint : Httpun.Request.t -> string option
(** Caller-supplied actor hint for dashboard audit attribution. *)

val sanitize_dashboard_actor_name : string -> string
(** Strip non-printable characters and clamp length so the actor name
    is safe to log / render. *)

val dashboard_actor_for_request :
  base_path:string -> Httpun.Request.t -> string option
(** Resolve the dashboard actor name from the request. *)

val is_verified_internal_keeper_request :
  base_path:string -> Httpun.Request.t -> bool
(** [true] when the request carries a verified internal-keeper token. *)

val sanitized_dashboard_actor_for_request :
  base_path:string -> Httpun.Request.t -> string option
(** [dashboard_actor_for_request] piped through
    [sanitize_dashboard_actor_name]. *)

(** {1 Origin / CORS} *)

val default_port_of_scheme : string option -> int option
(** Default port for [http]/[https]/[ws]/[wss], or [None]. *)

val normalize_loopback_host : string -> string
(** Map [127.0.0.1]/[::1]/[localhost] to a single canonical form so
    origin comparisons are scheme/host-equivalent. *)

val host_port_scheme_of_origin :
  string -> (string * int option * string option) option
(** Parse an [Origin] header value into [(host, port, scheme)]. *)

val host_port_of_request : Httpun.Request.t -> (string * int option) option
(** Host/port from the request's [Host] header. *)

val allow_anonymous_mutations : bool
(** Compile-time toggle: when [true] non-loopback mutations skip auth
    (test fixtures only). *)

val default_loopback_dev_mutation_origins : string list
(** Built-in allowlist of dev-loopback origins (e.g. Vite). *)

val configured_loopback_dev_mutation_origins : unit -> string list
(** Configured allowlist (env / TOML), unioned with the default. *)

val normalized_origin_key :
  string -> (string * int option * string option) option
(** Stable key for origin allowlist comparisons. *)

val is_allowlisted_loopback_dev_origin : string -> bool
(** [true] when [origin] matches the loopback dev allowlist. *)

val ensure_same_origin_browser_request :
  Httpun.Request.t -> (unit, Types.masc_error) result
(** Reject mutations from off-origin browsers; allows the loopback dev
    allowlist. *)

(** {1 Auth-error wire format} *)

val http_status_of_auth_error :
  Types.masc_error ->
  [> `Forbidden | `Internal_server_error | `Unauthorized ]
(** HTTP status to return for a given auth-domain error. *)

val server_state : Mcp_server.server_state option ref
(** Process-wide server state handle used by auth helpers when no
    state is threaded through. *)

val get_origin : Httpun.Request.t -> Httpun.Headers.value
(** Resolve the request's [Origin] header value (empty string when
    missing). *)

val public_read_cors_origin_opt :
  Httpun.Request.t -> Httpun.Headers.value option
(** Origin to echo back on public-read CORS responses; [None] when the
    request is not eligible for public-read. *)

val cors_allow_headers_value : string
(** Static [Access-Control-Allow-Headers] value used for protected
    routes. *)

val cors_headers : string -> (string * string) list
(** Build a CORS header set for [origin]. *)

val respond_json_with_cors :
  ?status:Httpun.Status.t ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Send a JSON body with CORS headers attached. *)

val public_read_cors_headers :
  Httpun.Request.t -> (string * Httpun.Headers.value) list
(** Header set for public-read responses (looser than the protected
    route policy). *)

val respond_public_read_json :
  ?status:Httpun.Status.t ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Public-read JSON responder. *)

val auth_error_json : Types.masc_error -> string
(** Render an auth error as the standard JSON envelope. *)

val respond_auth_error :
  Httpun.Request.t -> Httpun.Reqd.t -> Types.masc_error -> unit
(** Compose [http_status_of_auth_error] + [auth_error_json] + CORS. *)

val respond_agent_rate_limited :
  rl_key:string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Send a 429 Too Many Requests response for a per-agent rate-limit
    violation.  Includes [X-RateLimit-*] headers and CORS so browser
    clients can inspect the response. *)

val agent_rl_key_of_request : Httpun.Request.t -> string option
(** Extract a per-agent rate-limit key from the request.  Prefers the
    bearer token (SHA-256 prefix) over the declared agent-name header.
    Returns [None] for anonymous requests. *)

val check_agent_rate_limit :
  Httpun.Request.t -> Httpun.Reqd.t -> (unit, unit) result
(** Check the per-agent rate limit.  Returns [Ok ()] if allowed.
    Sends a 429 response and returns [Error ()] if rate-limited.
    Anonymous requests (no token, no agent header) are always allowed. *)

(** {1 Handler combinators}

    Each [with_*_auth] takes a handler that expects an authorised
    [server_state] and returns a [Httpun] handler.  Failure paths emit
    a structured auth error via [respond_auth_error].  All combinators
    apply per-agent rate limiting after successful auth. *)

val with_admin_auth :
  (Mcp_server.server_state ->
   Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Require admin-tier auth (operator MCP). *)

val is_public_read_path : String.t -> bool
(** [true] when [path] is on the public-read allowlist. *)

val resolve_agent_name_for_auth :
  base_path:string ->
  Httpun.Request.t ->
  token:string option -> (string option, Types.masc_error) result
(** Public wrapper of [resolve_agent_name_for_auth_raw]; the raw form
    is exposed for tests that exercise the underlying decision. *)

val authorize_permission_request :
  base_path:string ->
  permission:Types.permission ->
  Httpun.Request.t -> (unit, Types.masc_error) result
(** Check that the request carries [permission]. *)

val authorize_read_request :
  base_path:string -> Httpun.Request.t -> (unit, Types.masc_error) result
(** Check read-tier auth. *)

val authorize_tool_request :
  base_path:string ->
  tool_name:string -> Httpun.Request.t -> (unit, Types.masc_error) result
(** Check that the request is allowed to call [tool_name]. *)

val authorize_token_bound_permission_request :
  base_path:string ->
  permission:Types.permission ->
  Httpun.Request.t -> (string, Types.masc_error) result
(** Like [authorize_permission_request] but returns the token id used
    for auditing the call. *)

val is_dashboard_bootstrap_path : string -> bool
(** [true] when the path is part of the dashboard bootstrap surface
    (allowed without bearer token while loopback). *)

val not_initialized_response : string -> string
(** JSON body returned when the server is up but [server_state] is
    not yet hydrated. *)

val with_public_read :
  (Mcp_server.server_state ->
   Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Public-read combinator (no auth, looser CORS). *)

val with_read_auth :
  (Mcp_server.server_state ->
   Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Read-tier auth combinator. *)

val with_permission_auth :
  permission:Types.permission ->
  (Mcp_server.server_state ->
   Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Permission-tier combinator. *)

val with_tool_auth :
  tool_name:string ->
  (Mcp_server.server_state ->
   Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Tool-call auth combinator. *)

val with_token_permission_auth :
  permission:Types.permission ->
  (Mcp_server.server_state ->
   string -> Httpun.Request.t -> Httpun.Reqd.t -> unit) ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Like [with_permission_auth] but threads the token id into the
    handler so the handler can audit the call. *)

(** {1 Agent card surface} *)

val serve_agent_card :
  host:string -> port:int -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Serve the public [.well-known/agent-card.json] using the canonical
    [(host, port)] for absolute URLs. *)
