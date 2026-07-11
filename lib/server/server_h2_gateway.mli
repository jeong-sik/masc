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
  'a ->
  H2.Reqd.t ->
  unit
