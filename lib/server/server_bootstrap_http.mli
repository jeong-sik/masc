(** Server_bootstrap_http — HTTP listening socket setup + accept
    loop for the MASC MCP server.

    Three serve variants:
    - {!serve}: HTTP/1.1 only.
    - {!serve_h2}: HTTP/2 only (cleartext h2c).
    - {!serve_auto}: ALPN negotiation between the two.

    Internal: \[Http\] alias to {!Http_server_eio} stays private —
    callers reach config / socket types via {!Http_server_eio}
    directly. *)

val make_http_config :
  host:string -> port:int -> Http_server_eio.config
(** [make_http_config ~host ~port] builds the listener config from
    the resolved host / port pair.  Other config fields default
    via {!Http_server_eio.default_config}. *)

val listen_socket :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] as 'a ] Eio.Resource.t ->
  Http_server_eio.config ->
  'a Eio.Net.listening_socket_ty Eio.Resource.t
(** [listen_socket ~sw ~net config] binds + listens on
    [config.host:config.port] via {!Eio.Net.listen}.  Returns
    the listening-socket resource owned by the supplied switch.
    Raises if the host is not a valid IP literal. *)

val print_startup_banner :
  config:Http_server_eio.config ->
  resolved_base:string ->
  base_path:string ->
  masc_dir:string ->
  path_diagnostics:Server_base_path_diagnostics.t ->
  unit
(** [print_startup_banner ~config ~resolved_base ~base_path
      ~masc_dir ~path_diagnostics] prints the MASC server startup
    banner to stdout (host:port, base paths, optional diagnostics).
    Pinned at the contract seam — operator log scrapers parse the
    "MASC MCP Server listening on http://" line. *)

(** {1 Accept loops} *)

val serve :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  request_handler:(Eio.Net.Sockaddr.stream -> Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  unit
(** [serve ~sw ~clock ~socket ~request_handler] runs the HTTP/1.1
    accept loop until the switch is cancelled.  Errors are logged
    via {!Log.Misc.warn} and the connection closed; the loop
    continues. *)

val serve_h2 :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  h2_request_handler:(Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  unit
(** [serve_h2] is the HTTP/2 variant — cleartext h2c, no ALPN.
    Used when the operator explicitly enables H2 via env. *)

val serve_auto :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  socket:[> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  request_handler:(Eio.Net.Sockaddr.stream -> Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  h2_request_handler:(Eio.Net.Sockaddr.stream -> H2.Reqd.t -> unit) ->
  h2_error_handler:
    (Eio.Net.Sockaddr.stream -> ?request:H2.Request.t -> H2.Server_connection.error -> (H2.Headers.t -> H2.Body.Writer.t) -> unit) ->
  unit
(** [serve_auto] inspects the first request bytes and dispatches
    to either the HTTP/1.1 or HTTP/2 handler.  Used as the
    default serve loop so existing HTTP/1.1 clients keep working
    while H2-capable clients can upgrade. *)
