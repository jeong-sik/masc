(** The request entry every transport runs after it has classified the
    request's authority (RFC-0512 D2): client and agent rate limits, the MCP
    origin and protocol-version checks, the workspace precondition, then the
    route table through {!Http_server_eio.Router.dispatch}.

    The HTTP/1.1 adapter is {!http1_handler}; the HTTP/2 adapter is
    {!Server_h2_gateway.make_request_handler}. Both build an {!Http_reqd.t}
    and call {!serve}, so a route exists, is authenticated and answers the
    same way on both transports. *)

val serve
  :  routes:Http_server_eio.Router.t
  -> client_addr:Eio.Net.Sockaddr.stream
  -> Server_request_authority.classification
  -> Http_reqd.t
  -> unit
(** Answers a refused authority with 400 and an [error_code]; binds an
    admitted one to the request fiber and runs the admission steps above.

    A handler exception is answered by {!Http_reqd.response_state}. With no
    response yet it becomes a 500, or a 503 for [Auth.Auth_config_error]. An
    open streaming response is ended with {!Http_reqd.report_exn}: HTTP/2
    resets the stream, HTTP/1.1 stops the body and closes the connection.
    After a complete response the exception is only logged. Outside an open
    streaming response, the late-response shapes {!Http_reqd.Late_response}
    knows are logged at warn and get no second response. Cancellation
    propagates. *)

val respond_request_authority_bad_request
  :  error_code:string
  -> message:string
  -> Http_reqd.t
  -> unit
(** The 400 JSON body [{"error_code": …, "error": …}] a transport adapter
    answers for a request shape {!serve} never sees. *)

val http1_handler
  :  trust_policy:Server_request_authority.trust_policy
  -> Http_server_eio.Router.t
  -> Eio.Net.Sockaddr.stream
  -> Httpun.Reqd.t Gluten.Reqd.t
  -> unit
(** The httpun-eio connection handler: wraps the descriptor with its upgrade
    capability ({!Http_reqd.of_gluten}), classifies the [Host] field set and
    runs {!serve}. *)
