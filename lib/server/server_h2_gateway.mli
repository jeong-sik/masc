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
    parse or a handler it could not run. Its body is one of the fixed
    sentences of {!Http_error_body}, reserved in the request's ledger scope
    when one is bound. What failed is logged at error; an exception's text
    reaches the log only. The answer closes once
    its bytes drain. h2 opens it inside the call that reports a stream's
    failure, and there the stream's {!Http_h2_stream.Stream_end} is bound, so
    a peer that leaves it undrained past the stall bound gets the stream
    reset. An answer h2 opens on the connection reader waits for h2. *)

val make_request_handler
  :  trust_policy:Server_request_authority.trust_policy
  -> routes:Http_server_eio.Router.t
  -> stream_end:Http_h2_stream.Stream_end.t
  -> Eio.Net.Sockaddr.stream
  -> H2.Reqd.t
  -> unit
(** [routes] is the table the HTTP/1.1 listener dispatches on. [stream_end]
    is this request stream's scope; deferred body work and SSE producers run
    on its switch, and its response flushes get its stall bound. The switch
    is cancelled when a RST_STREAM goes either way, when the handler raises,
    when a response flush stalls, and when connection I/O ends
    ({!Server_bootstrap_http.serve_h2_connection}). The [:authority] field
    set is classified as the HTTP/1.1 [Host] set is, then the request takes
    the shared path, client-IP rate limit included. A handler called outside
    a listener's request ledger scope gets its own response capacity. *)

val make_table_request_handler
  :  trust_policy:Server_request_authority.trust_policy
  -> table:Server_account_table.t
  -> stream_end:Http_h2_stream.Stream_end.t
  -> Eio.Net.Sockaddr.stream
  -> H2.Reqd.t
  -> unit
(** {!make_request_handler} over {!Server_http_ingress.serve_table}: the
    HTTP/2 adapter of a server whose whole surface is its route table. *)
