(** Server_h2_gateway — HTTP/2 request and error handlers.

    Provides [make_request_handler] and [make_error_handler] closures
    consumed by [Server_runtime_bootstrap.run] when MASC_USE_H2 is set. *)

val make_error_handler :
  unit ->
  'a ->
  ?request:H2.Request.t ->
  H2.Server_connection.error ->
  (H2.Headers.t -> H2.Body.Writer.t) ->
  unit

val make_request_handler :
  trust_policy:Server_request_authority.trust_policy ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  server_start_time:float ->
  request_sw:Eio.Switch.t ->
  Eio.Net.Sockaddr.stream ->
  H2.Reqd.t ->
  unit
(** [sw] retains the server lifetime for durable MCP work and shared
    producers. [request_sw] belongs to this connection and is cancelled when
    connection I/O ends; body completions and SSE producers use that scope.
    The client address was ['a] while this handler discarded it, which is also
    how the per-client-IP limit the H1 ingress applies went missing on this
    transport. It is named now because the handler charges that bucket. *)
