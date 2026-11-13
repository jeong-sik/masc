(** Server_bootstrap_http — HTTP listening socket setup + accept
    loop for the MASC MCP server.

    Three serve variants:
    - {!serve}: HTTP/1.1 only.
    - {!serve_h2}: HTTP/2 only (cleartext h2c).
    - {!serve_auto}: h2 preface peek ({!Http_protocol_detect}) picks
      between the two on the same cleartext port. No TLS, no ALPN.

    Internal: \[Http\] alias to {!Http_server_eio} stays private —
    callers reach config / socket types via {!Http_server_eio}
    directly. *)

type bind_address_error = Invalid_host of string

val parse_bind_address : string -> (Ipaddr.t, bind_address_error) result
(** [parse_bind_address host] reads the host the server is told to bind as one
    IPv4 or IPv6 address. A name is not resolved: [localhost] is
    [Invalid_host], and so is an address no family can hold, such as
    [999.0.0.1]. *)

val bind_address_error_to_string : bind_address_error -> string

val make_http_config :
  address:Ipaddr.t -> port:int -> Http_server_eio.config
(** [make_http_config ~address ~port] builds the listener config. Its [host]
    is [address] written out by {!Ipaddr.to_string}. Other config fields
    default via {!Http_server_eio.default_config}. *)

val advertised_base_url : address:Ipaddr.t -> port:int -> string
(** The base URL {!make_http_config} writes for a listener bound to
    [address] when none is configured: [http://127.0.0.1:P] for a wildcard,
    [http://[::1]:P] for [::1]. {!Server_request_authority.make_trust_policy}
    reads it back as the explicit base URL. *)

val listen_tcp_result :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] as 'a ] Eio.Resource.t ->
  backlog:int ->
  Eio.Net.Sockaddr.stream ->
  ('a Eio.Net.listening_socket_ty Eio.Resource.t, string) result
(** Binds and listens on a TCP address via {!Eio.Net.listen}. A listener
    that does not bind is an [Error] that names the call and the Unix error
    (a port in use is [bind: Address already in use]). The account server
    and [masc auth preview] bind through this function. *)

val listen_socket_result :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] as 'a ] Eio.Resource.t ->
  address:Ipaddr.t ->
  Http_server_eio.config ->
  ('a Eio.Net.listening_socket_ty Eio.Resource.t, string) result
(** {!listen_tcp_result} on [address:config.port] with the backlog of
    [config]. *)

val listen_socket :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] as 'a ] Eio.Resource.t ->
  address:Ipaddr.t ->
  Http_server_eio.config ->
  'a Eio.Net.listening_socket_ty Eio.Resource.t
(** [listen_socket ~sw ~net ~address config] binds + listens on
    [address:config.port] via {!Eio.Net.listen}.  Returns
    the listening-socket resource owned by the supplied switch.
    [address] is the one {!make_http_config} wrote into [config]. *)

(** The HTTPS listener of one boot (RFC-0512 D6): its port, the TLS
    configuration built from {!Server_tls_material}, and where the
    certificate came from. *)
type https_listener =
  { https_port : int
  ; tls : Tls.Config.server
  ; certificate_source : Https_listener_metrics.certificate_source
  }

val https_listener_of_env :
  base_path:string -> bind_host:string -> (https_listener option, string) result
(** [Ok None] when [MASC_HTTPS_PORT] is 0. Otherwise loads or generates the
    certificate ({!Server_tls_material.load_or_generate}) and records it in
    {!Https_listener_metrics}. [Error] is the reason the listener cannot
    exist, for the operator; the caller refuses the boot with it. *)

val listen_https_socket :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] as 'a ] Eio.Resource.t ->
  address:Ipaddr.t ->
  config:Http_server_eio.config ->
  https_listener option ->
  (https_listener * 'a Eio.Net.listening_socket_ty Eio.Resource.t) option
(** Binds [address:https_port] like {!listen_socket}. A bind failure is
    recorded as {!Https_listener_metrics.Bind_failed}, logged, and answered
    with [None]: the cleartext listener still serves and HTTPS stays off
    until the next boot. *)

val print_startup_banner :
  config:Http_server_eio.config ->
  https:https_listener option ->
  resolved_base:string ->
  base_path:string ->
  masc_dir:string ->
  path_diagnostics:Server_base_path_diagnostics.t ->
  unit
(** [print_startup_banner ~config ~https ~resolved_base ~base_path
      ~masc_dir ~path_diagnostics] prints the MASC server startup
    banner to stdout (host:port, the HTTPS port when the listener exists,
    base paths, optional diagnostics).
    Pinned at the contract seam — operator log scrapers parse the
    "MASC MCP Server listening on http://" line. *)

(** {1 Internal helpers} *)

val with_cleanups_on_release :
  sw:Eio.Switch.t -> (unit -> unit) list -> unit
(** [with_cleanups_on_release ~sw cleanups] runs each cleanup on
    [sw] release.  Each cleanup is wrapped in its own [try/with] so
    a single non-[Cancelled] exception cannot prevent the remaining
    cleanups (RFC-0194 §3 PR-B spirit: an [Eio.Switch.on_release]
    callback must be all-or-nothing across its steps).
    [Eio.Cancel.Cancelled] propagates as usual so structured
    cancellation honors the enclosing fiber.  Cleanups run in the
    order supplied. *)

(** {1 Accept loops}

    The four loops below read and write every connection they accept through
    {!Server_connection_socket} (RFC-0518 D4, D6). A connection is closed
    when a write piece is not taken within
    {!Server_connection_socket.write_bound_s}, when the peer keeps its side
    open that long after the server closed its own, or when it is not ready
    within {!Server_connection_socket.preparation_bound_s}: the first bytes
    on the HTTP/1.1 and h2c loops, the protocol choice on the auto loop, the
    TLS handshake on the TLS loop. A connection that was not ready is logged
    at debug. *)

val serve :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  addr_label:string ->
  request_handler:(Eio.Net.Sockaddr.stream -> Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  unit
(** [serve ~sw ~clock ~socket ~addr_label ~request_handler] runs the
    HTTP/1.1 accept loop until the switch is cancelled.  Errors are
    logged via {!Log.Misc.warn} and the connection closed; the loop
    continues.  [addr_label] (e.g. ["0.0.0.0:8080"]) is embedded in
    every error log line as [[h1 <addr_label>]] so operators can
    identify which listener emitted the line when a process runs
    multiple HTTP servers. *)

val h2_config : unit -> H2.Config.t
(** The settings every H2 connection is created with, cleartext or TLS:
    server push off, and the stream limit and initial window from
    {!H2_response_limits}. *)

val serve_h2_connection :
  clock:_ Eio.Time.clock ->
  ?streams:Server_h2_stream_registry.t ->
  ?resources:Http_h2_response_ledger.t ->
  sw:Eio.Switch.t ->
  h2_request_handler:
    (stream_end:Http_h2_stream.Stream_end.t -> Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  Eio.Net.Sockaddr.stream ->
  _ Eio.Net.stream_socket ->
  unit
(** Run H2 connection I/O and a separate request scope. I/O completion or
    failure cancels pending requests and their children, including response
    producers, without waiting for an occupied CPU pool.

    Each request stream runs in its own scope in [streams], and
    [h2_request_handler] receives that scope as [stream_end]: the stream's
    switch and the bound on its response flushes. When [streams] is omitted,
    a fresh registry bounds response flushes by [clock] and
    {!Server_mcp_transport_http_headers.sse_stalled_after_s}.

    A stream's work and children are cancelled at once when a RST_STREAM goes
    either way: one the peer sends, one h2 writes for an error masc reported
    or found itself, or the RST_STREAM(NO_ERROR) h2 writes after a complete
    response while the request is still open. A handler exception resets the
    stream ([Raised]), and so does a response flush the peer leaves
    unanswered past the bound ([Stalled]). A finished response releases the
    entry when its work returns. Siblings and the connection keep running.

    The finite peer-stream limit comes from {!H2_response_limits}.
    [resources] shares payload capacity with other connections; when omitted,
    this connection gets its own capacity. The listener accept loops below
    create one shared capacity for all their H2 connections. *)

val serve_h2 :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  addr_label:string ->
  h2_request_handler:
    (stream_end:Http_h2_stream.Stream_end.t -> Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  unit
(** [serve_h2] is the HTTP/2 variant — cleartext h2c, no ALPN.
    Used when the operator explicitly enables H2 via env.
    [addr_label] is embedded as [[h2 <addr_label>]] in error logs. *)

val serve_auto :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  addr_label:string ->
  request_handler:(Eio.Net.Sockaddr.stream -> Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  h2_request_handler:
    (stream_end:Http_h2_stream.Stream_end.t -> Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  unit
(** [serve_auto] inspects the first request bytes and dispatches
    to either the HTTP/1.1 or HTTP/2 handler.  Used as the
    default serve loop so existing HTTP/1.1 clients keep working
    while H2-capable clients can upgrade.  [addr_label] is
    embedded as [[auto <addr_label>]] in error logs. *)

val serve_tls :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  addr_label:string ->
  tls:Tls.Config.server ->
  request_handler:(Eio.Net.Sockaddr.stream -> Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  h2_request_handler:
    (stream_end:Http_h2_stream.Stream_end.t -> Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  unit
(** [serve_tls] is the HTTPS accept loop (RFC-0512 D6). Every accepted
    connection runs the TLS handshake with [tls]; the ALPN result picks the
    connection handler: [h2] runs {!serve_h2_connection} with a payload
    capacity shared by this listener's HTTP/2 connections, [http/1.1] and no
    ALPN run httpun. A handshake that ends in an alert, a protocol failure or
    a closed peer, or that is not completed within the preparation bound, is
    counted in {!Https_listener_metrics} and logged at debug. The listener's state is {!Https_listener_metrics}, never the
    cleartext listener's {!Transport_metrics} mode. [addr_label] is embedded
    as [[tls <addr_label>]] in log lines. *)
