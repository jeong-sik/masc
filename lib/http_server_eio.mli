(** Http_server_eio — Eio-native HTTP/1.1 server using
    [httpun-eio].

    Sister module to {!Http_server_h2} (cycle 164, the H2
    wrapper).  Conflict-free with [httpun-ws-eio] (no cohttp 6.x
    dependency).  Includes built-in routes for [/health],
    [/ready], [/metrics], plus the streamable MCP endpoint.

    Internal: ~25+ helpers stay private — exception
    \[Shutdown] (graceful-shutdown signaling), the 5 built-in
    handlers ([health_handler], [ready_handler],
    [metrics_handler], [mcp_post_handler], [mcp_get_handler]),
    \[default_routes] (the route list assembled from those
    handlers), \[with_streamable_mcp_request_handler],
    \[make_request_handler] (router → request_handler
    converter), \[error_handler] (httpun connection error
    handler), \[run] (server accept loop with backoff), and
    \[start] (Eio_main entry with signal handlers).  External
    callers reach the server through the [Server_bootstrap_*]
    facade modules instead of these internals.

    @see <https://github.com/anmonteiro/httpun> httpun
    documentation *)

(** {1 Server configuration} *)

type config = {
  port : int;
  host : string;
  max_connections : int;
}
(** Concrete record because callers (test fixtures + server
    bootstrap) construct + tweak fields directly. *)

val default_config : config
(** [default_config] is
    [{ port = Env_config_core.masc_http_port_int ();
       host = MASC_HTTP_HOST or default;
       max_connections = MASC_HTTP_MAX_CONNECTIONS or 128 }].
    Reads env at module load time — restart required for env
    changes to take effect. *)

(** {1 Request handler type} *)

type request_handler = Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Standard httpun request handler shape.  Used by
    {!Router.t} and {!make_request_handler}. *)

(** {1 Compression (Compact Protocol v4)} *)

(** HTTP compression with optional dictionary-based zstd.
    Trained dictionary achieves ~70%p better compression than
    standard zstd on small messages (32-2048 bytes) — see the
    {!Compress.compress} docstring. *)
module Compression : sig
  val accepts_zstd : Httpun.Request.t -> bool
  (** [accepts_zstd request] is [true] when the
      [Accept-Encoding] header lists [zstd]. *)

  val accepts_zstd_dict : Httpun.Request.t -> bool
  (** [accepts_zstd_dict request] is [true] when the
      [Accept-Encoding] header lists [zstd-dict] or
      [zstd;dict=masc]. *)

  val compress :
    ?level:int -> string -> string * string option
  (** [compress ?level data] returns [(payload, encoding)] —
      [encoding = None] means data was kept as-is (below
      compression threshold or no benefit), [Some name]
      identifies the content-encoding header value to set. *)

  val compress_zstd : ?level:int -> string -> string * bool
  (** [compress_zstd ?level data] is the legacy
      no-dictionary path.  Returns [(payload, did_compress)] —
      data shorter than 256 bytes is kept as-is. *)
end

(** {1 Response helpers} *)

(** Status / body / streaming response writers over the
    [httpun] streaming API.  Every helper closes the response
    body except the 304 path in [html_cached]. *)
module Response : sig
  val text :
    ?status:Httpun.Status.t -> string -> Httpun.Reqd.t -> unit
  (** Plain-text response.  Default status [`OK].  Sets
      [content-type: text/plain; charset=utf-8] +
      [content-length]. *)

  val html :
    ?status:Httpun.Status.t ->
    ?headers:(string * string) list ->
    string ->
    Httpun.Reqd.t ->
    unit
  (** HTML response.  Default status [`OK].  Caller-supplied
      headers append after [content-type] / [content-length]. *)

  val bytes :
    ?status:Httpun.Status.t ->
    ?headers:(string * string) list ->
    content_type:string ->
    string ->
    Httpun.Reqd.t ->
    unit
  (** Arbitrary-content response with caller-supplied
      [content_type]. *)

  val json :
    ?status:Httpun.Status.t ->
    ?compress:bool ->
    ?extra_headers:(string * string) list ->
    ?request:Httpun.Request.t ->
    string ->
    Httpun.Reqd.t ->
    unit
  (** JSON response with optional zstd compression.  Default
      status [`OK].  When [compress = true] (default) AND
      [?request] supplies a [Compression.accepts_zstd] match,
      uses dictionary-based compression for small messages
      (~70% reduction vs ~6% with standard zstd). *)

  val sunset_headers :
    date:string ->
    ?successor:string ->
    unit ->
    (string * string) list
  (** RFC 8594 deprecation headers ([Sunset], [Deprecation],
      optional [Link] with [rel="successor-version"]).  [date]
      MUST be HTTP-date format (RFC 7231 S7.1.1.1).  Pass via
      [Response.json ~extra_headers:(sunset_headers ...) ...]. *)

  val json_raw :
    ?status:Httpun.Status.t -> string -> Httpun.Reqd.t -> unit
  (** Legacy JSON response without compression check (backwards
      compatible — kept for callers that pre-date the
      compression-aware {!json}). *)

  val html_cached :
    ?status:Httpun.Status.t ->
    etag:string ->
    request:Httpun.Request.t ->
    string ->
    Httpun.Reqd.t ->
    unit
  (** HTML response with ETag + conditional 304 support.  When
      the request If-None-Match header matches the quoted etag
      value, returns [`Not_modified] with no body; otherwise
      serves the full response with ETag + zstd compression
      when the client accepts it.  Used for static dashboard
      HTML. *)

  val not_found : Httpun.Reqd.t -> unit
  (** Pinned ["404 Not Found"] body, status [`Not_found]. *)

  val method_not_allowed : Httpun.Reqd.t -> unit
  (** Pinned ["405 Method Not Allowed"] body, status
      [`Method_not_allowed]. *)

  val internal_error : string -> Httpun.Reqd.t -> unit
  (** [internal_error msg reqd] returns status
      [`Internal_server_error] with body of the form
      [500 Internal Server Error: <msg>] (literal prefix
      concatenated with the caller-supplied message). *)
end

(** {1 Request helpers} *)

(** Per-request projections + body readers.  Body size is
    capped at {!max_body_bytes}; oversized requests respond
    [`Payload_too_large] before the handler is invoked. *)
module Request : sig
  val default_max_body_bytes : int
  (** [20 * 1024 * 1024] (= 20 MiB).  The hard-coded default
      when no env override is set. *)

  val max_body_bytes : int
  (** Effective max body size, resolved at module-load time
      from [MASC_MCP_MAX_BODY_BYTES] (preferred) or
      [MCP_MAX_BODY_BYTES] (legacy), falling back to
      {!default_max_body_bytes}.  Restart required for env
      changes. *)

  val read_body_async :
    Httpun.Reqd.t -> (string -> unit) -> unit
  (** [read_body_async reqd callback] reads the request body
      via [schedule_read] loops; [callback body_str] fires on
      EOF.  413 / 500 errors auto-respond before [callback] is
      invoked. *)

  val read_body_sync :
    Httpun.Reqd.t -> (string, string) result
  (** [read_body_sync reqd] is the Promise-backed synchronous
      wrapper.  Returns [Ok body] or [Error message]; size +
      transport errors are translated into the [Error] string
      and a 4xx/5xx HTTP response is auto-sent. *)

  val path : Httpun.Request.t -> string
  (** [path request] is the path portion of the URI (everything
      before [?]). *)

  val method_ : Httpun.Request.t -> Httpun.Method.t
  (** Convenience: [request.meth]. *)

  val header : Httpun.Request.t -> string -> string option
  (** [header request name] looks up [name] in
      [request.headers]. *)
end

(** {1 Router} *)

(** Path + method router with prefix-match support.  Exact
    matches take precedence over prefix matches (longest prefix
    wins among prefix matches). *)
module Router : sig
  type route = {
    path : string;
    methods : Httpun.Method.t list;
    handler : request_handler;
  }
  (** [path] uses the [PREFIX:] sentinel internally for
      prefix-match routes; callers should use {!prefix_get} /
      {!prefix_post} instead of crafting the sentinel
      manually. *)

  type resolution =
    [ `Matched of route
    | `Method_not_allowed
    | `Not_found ]

  type t = route list

  val empty : t

  val add :
    path:string ->
    methods:Httpun.Method.t list ->
    handler:request_handler ->
    t ->
    t
  (** Generic add; prefer the typed wrappers below. *)

  val get : string -> request_handler -> t -> t
  val post : string -> request_handler -> t -> t

  val any : string -> request_handler -> t -> t
  (** [any path handler routes] registers handler for GET /
      POST / PUT / DELETE / OPTIONS. *)

  val prefix_get : string -> request_handler -> t -> t
  (** [prefix_get prefix handler routes] matches any GET whose
      path starts with [prefix]. *)

  val prefix_post : string -> request_handler -> t -> t

  val resolve : t -> Httpun.Request.t -> resolution
  (** [resolve routes request] returns [`Matched route] when
      either an exact path+method match exists OR (no exact
      match) the longest prefix match exists.  Returns
      [`Method_not_allowed] when path matches but method does
      not, [`Not_found] otherwise. *)

  val dispatch : t -> request_handler
  (** [dispatch routes request reqd] wires {!resolve} to the
      route's handler, falling back to {!Response.not_found} /
      {!Response.method_not_allowed} based on the resolution. *)
end
