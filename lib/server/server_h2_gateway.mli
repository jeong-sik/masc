(** The HTTP/2 adapter (RFC-0512 D2). One h2 stream becomes one
    {!Http_reqd.t} and runs {!Server_http_ingress.serve}, the same entry
    HTTP/1.1 runs, so the route table is the only place a route exists. *)

val make_error_handler
  :  unit
  -> 'a
  -> ?request:H2.Request.t
  -> H2.Server_connection.error
  -> (H2.Headers.t -> H2.Body.Writer.t)
  -> unit
(** The connection-level error handler h2 calls for a request it could not
    parse or a handler it could not run. Its one-line diagnostic is reserved
    in the request's ledger scope when one is bound. *)

val make_request_handler
  :  trust_policy:Server_request_authority.trust_policy
  -> routes:Http_server_eio.Router.t
  -> request_sw:Eio.Switch.t
  -> Eio.Net.Sockaddr.stream
  -> H2.Reqd.t
  -> unit
(** [routes] is the table the HTTP/1.1 listener dispatches on. [request_sw]
    belongs to this request stream and is cancelled when the peer resets the
    stream or connection I/O ends; deferred body work and SSE producers use
    that scope. The [:authority] field set is classified as the HTTP/1.1
    [Host] set is, then the request takes the shared path, client-IP rate
    limit included. A handler called outside a listener's request scope gets
    its own response capacity. *)
