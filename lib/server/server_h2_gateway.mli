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
  routes:Http_server_eio.Router.t ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  server_start_time:float ->
  request_sw:Eio.Switch.t ->
  Eio.Net.Sockaddr.stream ->
  H2.Reqd.t ->
  unit
(** [routes] is the table the HTTP/1 listener dispatches on. An arm runs the
    gate that goes with the kind the table records for its request
    ({!Server_h2_route_gate}), so the kind is written once, in the HTTP/1
    registration. A request the table has no route for is answered 404 and a
    method it has no route for is answered 405, as on HTTP/1.

    [sw] retains the server lifetime for durable MCP work and shared
    producers. [request_sw] belongs to this request stream and is cancelled
    when the peer resets the stream or connection I/O ends; body completions
    and SSE producers use that scope.
    The client address was ['a] while this handler discarded it, which is also
    how the per-client-IP limit the H1 ingress applies went missing on this
    transport. It is named now because the handler charges that bucket. *)
