(** Server_routes_http_runtime — runtime route handlers for the
    HTTP/1.1 listener (health / liveness / readiness / OPTIONS) +
    shared helpers used by sister route modules.

    Open'd by {!Server_routes_http_routes_frontend} and
    {!Server_routes_http_routes_activity} so all top-level
    bindings are part of the public surface.  The Http module
    alias stays private. *)

val is_dashboard_spa_deep_link : string -> bool
(** [is_dashboard_spa_deep_link path] returns [true] iff [path]
    is a dashboard SPA deep link that should be served by the
    SPA shell rather than rejected as 404.

    Three rules pinned at the contract seam:
    - starts with [/dashboard/]
    - NOT a [/dashboard/assets/] path (those have their own
      asset handler)
    - NOT [/dashboard/credits] (which has a dedicated handler)

    A future "let's add /dashboard/api/..." route reopens this
    classification — pinning so the SPA fallback does not
    accidentally swallow API routes. *)

(** {1 CORS} *)

val cors_preflight_headers : string -> (string * string) list
(** [cors_preflight_headers origin] returns the 4-header
    CORS preflight response for [OPTIONS] requests:
    [access-control-allow-origin] / [-allow-methods]
    ([GET, POST, DELETE, OPTIONS]) / [-allow-headers] /
    [-expose-headers] ([Mcp-Session-Id, Mcp-Protocol-Version]).
    Pinned method set + exposed headers are the operator-visible
    contract — runbook integrations key off these literals. *)

(** {1 JSON-RPC error envelope} *)

val json_rpc_error : int -> string -> string
(** [json_rpc_error code message] returns the canonical
    JSON-RPC 2.0 error envelope as a string:
    [{"jsonrpc":"2.0","error":{"code":<code>,"message":"<msg>"},"id":null}].
    Message is `String.escaped`-quoted; callers must not pre-
    escape. *)

val is_http_error_response : Yojson.Safe.t -> bool
(** [is_http_error_response json] returns [true] when [json] is
    a JSON-RPC 2.0 response with [id = null] AND [error.code]
    in [-32700] (Parse error) / [-32600] (Invalid Request).
    Mirrors the predicate in
    {!Server_mcp_transport_http_headers}; duplicated here
    because the route layer needs it before the transport
    headers module is reachable. *)

(** {1 Server uptime} *)

val server_start_time : float
(** Captured at module init via {!Unix.gettimeofday}.  The
    [/health] endpoint computes uptime as
    [now - server_start_time].  Pinned as a float because the
    health renderer formats with second precision (no micro). *)

val configured_http_port : unit -> int
val configured_http_host : unit -> string
(** Aliases over {!Env_config_core.masc_http_port_int} /
    {!Env_config_core.masc_host}.  Each call re-reads the env
    var, supporting tests that override mid-process. *)

val advertised_host_port :
  Httpun.Request.t -> string * int
(** [advertised_host_port request] returns the
    [(canonical_host, port)] pair the server should advertise
    in JSON projections.  Reads the [Host:] header (if present)
    via {!parse_host_port}, then routes the host through
    {!Transport_read_model.normalize_advertised_host} (loopback
    aliases collapse to the configured default).  Falls back to
    [(configured_http_host (), configured_http_port ())] when
    the header is absent. *)

(** {1 Discovery / status JSON} *)

val websocket_discovery_json : Httpun.Request.t -> Yojson.Safe.t
(** [websocket_discovery_json request] returns the WebSocket
    discovery payload using {!advertised_host_port}.  Always
    sets [include_configured = true] so dashboards see the
    enabled / runtime-listening pair.  Used by [GET /ws.json]
    on both HTTP/1.1 and HTTP/2 listeners. *)

val transport_json : Httpun.Request.t -> Yojson.Safe.t
(** [transport_json request] returns the full transport status
    JSON (HTTP + WS + protocol set).  Sub-projection used by
    {!make_health_json}'s [transport] field. *)

(** {1 Health endpoints} *)

val health_path_diagnostics :
  unit -> Server_base_path_diagnostics.t
(** [health_path_diagnostics ()] resolves the base-path
    diagnostics for the [/health] response.  When the runtime
    state is initialised, reads from
    [state.room_config.base_path]; otherwise falls back to the
    default base path computed from env. *)

val make_health_json :
  ?listener:string -> Httpun.Request.t -> Yojson.Safe.t
(** [make_health_json ?listener request] builds the full
    [/health] JSON body.  [listener] defaults to ["http/1.1"]
    and is overridden to ["h2"] by the H2 gateway.

    {2 Top-level keys (operator-visible contract)}

    [status] / [server] / [version] / [release_version] /
    [build] / [protocol] (default + listener + supported list) /
    [transport] / [paths] / [uptime] / [sse_clients] /
    [startup] / [subsystems] / [feature_flags] / [gc] /
    [keeper_fibers] / [keeper_config_parse_error_count] /
    [keeper_config_parse_errors] / [keeper_config_unknown_key_count] /
    [keeper_config_unknown_keys] / [lazy_task_boot_guard_fires_total].

    {2 lazy_task_boot_guard_fires_total contract (P2 silent-
    failure fix)}

    Surfaces {!Prometheus.metric_total} for
    [masc_lazy_task_boot_guard_fired_total].  Without this
    field, an operator hitting [/health] would see ["status":
    "ok"] while keepers had silently failed to start.  Pinning
    at the contract seam: a future "drop unused metric" PR
    must touch this. *)

val health_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [health_handler request reqd] writes
    {!make_health_json} as the response body. *)

val liveness_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [liveness_handler request reqd] always responds [200] as
    soon as the HTTP accept loop is running.  Does NOT depend
    on server_state initialisation — Kubernetes / Railway
    liveness probe target.  Body:
    [{"live": true, "startup": <Server_startup_state.to_yojson>}]. *)

val readiness_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [readiness_handler request reqd] responds [200] only when
    [Server_startup_state.state_ready] is [true].

    | State | HTTP status | Body fields |
    |---|---|---|
    | ready | [200 OK] | [ready: true], [phase], [backend_mode] |
    | not ready | [503 Service Unavailable] | [ready: false], [phase], [elapsed_sec] |

    Pinned at the contract seam — orchestrators (k8s, Railway)
    key off the [200] vs [503] distinction. *)

(** {1 Board} *)

val board_post_detail_json :
  response_format:string ->
  post_id:string ->
  [> `OK | `Not_found ] * string
(** [board_post_detail_json ~response_format ~post_id] returns
    [(status, json_string)] for [GET /api/v1/board/<post_id>].

    {2 response_format values (case-insensitive, trimmed)}

    | Format | Shape |
    |---|---|
    | [["flat"]] | post fields + [comments] sibling |
    | otherwise (default [["nested"]]) | [{"post": ..., "comments": [...]}] |

    {2 Status / body}

    | Outcome | Status | Body |
    |---|---|---|
    | Post missing | [404 Not Found] | [{"error":"Post not found"}] |
    | Found | [200 OK] | per response_format |

    Comment fetch errors (rare) silently degrade to empty
    comment list rather than failing the whole response. *)

(** {1 OPTIONS} *)

val options_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [options_handler request reqd] handles [OPTIONS *] and
    [OPTIONS <path>] CORS preflights.  Always responds
    [204 No Content] with {!cors_preflight_headers} for the
    request origin and [content-length: 0]. *)
