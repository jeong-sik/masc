(** Http_server_eio — Eio-native HTTP/1.1 server using
    [httpun-eio].

    Sister module to {!Http_server_h2} (cycle 164, the H2
    wrapper).  Conflict-free with [httpun-ws-eio] (no cohttp 6.x
    dependency).  Includes built-in routes for [/health],
    [/ready], plus the streamable MCP endpoint.

    Internal: helpers stay private — exception
    \[Shutdown] (graceful-shutdown signaling), the 5 built-in
    handlers ([health_handler], [ready_handler],
    [mcp_post_handler], [mcp_get_handler]),
    \[default_routes] (the route table assembled from those
    handlers), \[with_streamable_mcp_request_handler],
    \[make_request_handler] (router → request_handler
    converter), and \[error_handler] (httpun connection error
    handler).  The server accept loop lives in the
    [Server_bootstrap_*] facade modules; the [Eio_main] entry
    point (with signal handlers) lives in the executable
    [bin/main_eio.ml] (and sibling [bin/*_eio.ml] binaries).
    External callers reach the server through the facade modules
    instead of these internals.

    @see <https://github.com/anmonteiro/httpun> httpun
    documentation *)

(** {1 Server configuration} *)

(** Concrete record because callers (test fixtures + server
    bootstrap) construct + tweak fields directly. *)
type config =
  { port : int
  ; host : string
  ; max_connections : int
  ; listen_backlog : int
  }

(** [default_config] is
    [{ port = Env_config_core.masc_http_port_int ();
       host = MASC_HTTP_HOST or default;
       max_connections = MASC_HTTP_MAX_CONNECTIONS or 512;
       listen_backlog = MASC_TCP_LISTEN_BACKLOG or 128 }].
    Reads env at module load time — restart required for env
    changes to take effect. *)
val default_config : config

(** {1 Request handler type} *)

(** Standard httpun request handler shape.  Used by
    {!Router.t} and {!make_request_handler}. *)
type request_handler = Httpun.Request.t -> Httpun.Reqd.t -> unit

(** {1 Compression (Compact Protocol v4)} *)

(** HTTP compression with optional dictionary-based zstd.
    Trained dictionary achieves ~70%p better compression than
    standard zstd on small messages (32-2048 bytes) — see the
    {!Compress.compress} docstring. *)
module Compression : sig
  (** [accepts_zstd request] is [true] when the
      [Accept-Encoding] header lists [zstd]. *)
  val accepts_zstd : Httpun.Request.t -> bool

  (** [accepts_zstd_dict request] is [true] when the
      [Accept-Encoding] header lists [zstd-dict] or
      [zstd;dict=masc]. *)
  val accepts_zstd_dict : Httpun.Request.t -> bool

  (** [compress ?level data] returns [(payload, encoding)] —
      [encoding = None] means data was kept as-is (below
      compression threshold or no benefit), [Some name]
      identifies the content-encoding header value to set. *)
  val compress : ?level:int -> string -> string * string option

  (** [compress_zstd ?level data] is the legacy
      no-dictionary path.  Returns [(payload, did_compress)] —
      data shorter than 256 bytes is kept as-is.  Raw zstd
      compression is delegated to {!Compression_codec}, which owns
      compression failure diagnostics. *)
  val compress_zstd : ?level:int -> string -> string * bool

  (** [compress_zstd_result ~original result] adapts the shared codec result to
      the legacy HTTP zstd response contract. Dictionary-compressed payloads
      cannot be advertised as plain [zstd], so they return [original, false]. *)
  val compress_zstd_result :
    original:string -> Compression_codec.compress_result -> string * bool
end

(** {1 Response helpers} *)

(** Status / body / streaming response writers over the
    [httpun] streaming API.  Every helper closes the response
    body except the 304 path in [html_cached]. *)
module Response : sig
  (** JSON response content type used by {!json} and header-order
      regression tests. *)
  val json_content_type : string

  (** Build deterministic content headers around the mandatory
      [content-type] / [content-length] pair.  Optional header segments
      preserve caller order as [before_headers], core headers,
      [after_headers], then [tail_headers]. *)
  val content_headers
    :  ?before_headers:(string * string) list
    -> ?after_headers:(string * string) list
    -> ?tail_headers:(string * string) list
    -> content_type:string
    -> string
    -> Httpun.Headers.t

  (** Plain-text response.  Default status [`OK].  Sets
      [content-type: text/plain; charset=utf-8] +
      [content-length]. *)
  val text : ?status:Httpun.Status.t -> string -> Httpun.Reqd.t -> unit

  (** HTML response.  Default status [`OK].  Caller-supplied
      headers append after [content-type] / [content-length]. *)
  val html
    :  ?status:Httpun.Status.t
    -> ?headers:(string * string) list
    -> string
    -> Httpun.Reqd.t
    -> unit

  (** Arbitrary-content response with caller-supplied
      [content_type]. *)
  val bytes
    :  ?status:Httpun.Status.t
    -> ?headers:(string * string) list
    -> content_type:string
    -> string
    -> Httpun.Reqd.t
    -> unit

  (** Empty response.  Default status [`No_content].  Sends no
      content-type header; always includes [content-length: 0] so
      keep-alive clients and proxies see an explicit end-of-body. *)
  val empty : ?status:Httpun.Status.t -> Httpun.Reqd.t -> unit

  (** JSON response with optional zstd compression.  Default
      status [`OK].  When [compress = true] (default) AND
      [?request] or the request attached to [reqd] supplies an
      [Accept-Encoding: zstd] match,
      uses dictionary-based compression for small messages
      (~70% reduction vs ~6% with standard zstd). *)
  val json
    :  ?status:Httpun.Status.t
    -> ?compress:bool
    -> ?extra_headers:(string * string) list
    -> ?request:Httpun.Request.t
    -> string
    -> Httpun.Reqd.t
    -> unit

  val json_value
    :  ?status:Httpun.Status.t
    -> ?compress:bool
    -> ?extra_headers:(string * string) list
    -> ?request:Httpun.Request.t
    -> Yojson.Safe.t
    -> Httpun.Reqd.t
    -> unit

  (** RFC 8594 deprecation headers ([Sunset], [Deprecation],
      optional [Link] with [rel="successor-version"]).  [date]
      MUST be HTTP-date format (RFC 7231 S7.1.1.1).  Pass via
      [Response.json ~extra_headers:(sunset_headers ...) ...]. *)
  val sunset_headers : date:string -> ?successor:string -> unit -> (string * string) list

  (** Legacy JSON response without compression check (backwards
      compatible — kept for callers that pre-date the
      compression-aware {!json}). *)
  val json_raw : ?status:Httpun.Status.t -> string -> Httpun.Reqd.t -> unit

  (** HTML response with ETag + conditional 304 support.  When
      the request If-None-Match header matches the quoted etag
      value, returns [`Not_modified] with no body; otherwise
      serves the full response with ETag + zstd compression
      when the client accepts it.  Used for static dashboard
      HTML. *)
  val html_cached
    :  ?status:Httpun.Status.t
    -> etag:string
    -> request:Httpun.Request.t
    -> string
    -> Httpun.Reqd.t
    -> unit

  (** Pinned ["404 Not Found"] body, status [`Not_found]. *)
  val not_found : Httpun.Reqd.t -> unit

  (** Pinned ["405 Method Not Allowed"] body, status
      [`Method_not_allowed]. *)
  val method_not_allowed : Httpun.Reqd.t -> unit

  (** [internal_error msg reqd] returns status
      [`Internal_server_error] with body of the form
      [500 Internal Server Error: <msg>] (literal prefix
      concatenated with the caller-supplied message). *)
  val internal_error : string -> Httpun.Reqd.t -> unit
end

(** {1 Late-response failure classifier (#13059)} *)

(** Classification helper for the cancellation-vs-late-write race.

    When a handler's request is cancelled (peer closed, deadline hit,
    or upstream switch failed) the underlying writer enters either
    "invalid state" or "closed writer" — calling
    {!Response.internal_error} from a top-level handler
    [exception] arm at that point raises a *secondary* failure that
    masks the original cancellation.  The classifier identifies the
    two well-known failure shapes so callers can downgrade to a
    log-and-skip rather than emit a 500 onto a closed wire. *)
module Late_response : sig
  (** [classify_write_failure exn] returns [Some msg] when [exn] is
      one of the two well-known late-response failure modes:

      - [Failure "httpun.Reqd.respond_with_string: invalid state ..."]
        — httpun rejected a write because the response handle
        already moved past the writable state.
      - [Failure "cannot write to closed writer"] — the underlying
        writer was closed while a deferred handler was still
        attempting to drain.

      Returns [None] for every other exception (including
      [Eio.Cancel.Cancelled] which the caller MUST re-raise rather
      than classify). *)
  val classify_write_failure : exn -> string option
end

(** {1 Request helpers} *)

(** Per-request projections + body readers.  Body size is
    capped at {!max_body_bytes}; oversized requests respond
    [`Payload_too_large] before the handler is invoked. *)
module Request : sig
  (** [20 * 1024 * 1024] (= 20 MiB).  The hard-coded default
      when no env override is set. *)
  val default_max_body_bytes : int

  (** Effective max body size, resolved at module-load time
      from [MASC_MAX_BODY_BYTES] (preferred) or
      [MCP_MAX_BODY_BYTES] (legacy), falling back to
      {!default_max_body_bytes}.  Restart required for env
      changes. *)
  val max_body_bytes : int

  (** [read_body_async reqd callback] reads the request body
      via [schedule_read] loops; [callback body_str] fires on
      EOF.  413 / 500 errors auto-respond before [callback] is
      invoked. *)
  val read_body_async : Httpun.Reqd.t -> (string -> unit) -> unit

  (** [read_body_sync reqd] is the Promise-backed synchronous
      wrapper.  Returns [Ok body] or [Error message]; size +
      transport errors are translated into the [Error] string
      and a 4xx/5xx HTTP response is auto-sent. *)
  val read_body_sync : Httpun.Reqd.t -> (string, string) result

  (** [path request] is the path portion of the URI (everything
      before [?]). *)
  val path : Httpun.Request.t -> string

  (** Convenience: [request.meth]. *)
  val method_ : Httpun.Request.t -> Httpun.Method.t

  (** [header request name] looks up [name] in
      [request.headers]. *)
  val header : Httpun.Request.t -> string -> string option
end

(** {1 Router} *)

(** Path + method router with prefix-match support.  Exact
    matches take precedence over prefix matches (longest prefix
    wins among prefix matches). *)
module Router : sig
  type route_kind = Exact | Prefix

  (** The Gluten protocol-upgrade capability, available only at the
      httpun-eio connection-handler boundary.  WebSocket-upgrade routes
      ({!ws_get}) need it to drive the post-101 connection; plain routes
      do not.  RFC-0281. *)
  type upgrade = Gluten.impl -> unit

  (** A WebSocket-upgrade route handler.  Receives the per-request
      {!upgrade} capability in addition to the request + descriptor. *)
  type ws_handler =
    upgrade:upgrade -> Httpun.Request.t -> Httpun.Reqd.t -> unit

  (** A route either handles the request in-band ([Plain]) or upgrades
      the connection to WebSocket ([Ws]).  RFC-0281 S3.3. *)
  type route_target =
    | Plain of request_handler
    | Ws of ws_handler

  type route =
    { kind : route_kind
    ; path : string
    ; methods : Httpun.Method.t list
    ; handler : route_target
    }

  type resolution =
    [ `Matched of route
    | `Method_not_allowed
    | `Not_found
    ]

  (** Indexed dispatch table.  Route registration updates method-specific
      exact path tables and prefix tries at build time, so request dispatch
      does not scan/sort the full endpoint list or perform per-candidate
      method-list membership checks. *)
  type t

  val create : unit -> t
  val route_count : t -> int
  val routes : t -> route list

  (** Generic add; prefer the typed wrappers below. *)
  val add
    :  path:string
    -> methods:Httpun.Method.t list
    -> handler:request_handler
    -> t
    -> t

  val get : string -> request_handler -> t -> t
  val post : string -> request_handler -> t -> t

  (** [any path handler routes] registers handler for GET /
      POST / PUT / DELETE / OPTIONS. *)
  val any : string -> request_handler -> t -> t

  (** [ws_get path handler routes] registers a WebSocket-upgrade route
      on GET [path].  The handler receives the Gluten {!upgrade}
      capability so it can drive the post-101 connection.  RFC-0281. *)
  val ws_get : string -> ws_handler -> t -> t

  (** [prefix_get prefix handler routes] matches any GET whose
      path starts with [prefix]. *)
  val prefix_get : string -> request_handler -> t -> t

  val prefix_post : string -> request_handler -> t -> t

  (** [prefix_delete prefix handler routes] matches any DELETE whose
      path starts with [prefix]. *)
  val prefix_delete : string -> request_handler -> t -> t

  (** [prefix_put prefix handler routes] matches any PUT whose
      path starts with [prefix]. *)
  val prefix_put : string -> request_handler -> t -> t

  (** [resolve routes request] returns [`Matched route] when
      either an exact path+method match exists OR the
      longest prefix match for that method exists.  Returns
      [`Method_not_allowed] when an exact path exists but no
      route for the request method exists, [`Not_found]
      otherwise. *)
  val resolve : t -> Httpun.Request.t -> resolution

  (** [dispatch routes ?upgrade request reqd] wires {!resolve} to the
      route's handler, falling back to {!Response.not_found} /
      {!Response.method_not_allowed} based on the resolution.

      [?upgrade] supplies the Gluten upgrade capability for {!Ws}
      routes.  When a {!Ws} route is matched but [?upgrade] is absent
      (e.g. the HTTP/2 dispatch path), responds [`Upgrade_required]
      (426) — an explicit error, never a silent drop.  RFC-0281. *)
  val dispatch
    :  t
    -> ?upgrade:upgrade
    -> Httpun.Request.t
    -> Httpun.Reqd.t
    -> unit
end
