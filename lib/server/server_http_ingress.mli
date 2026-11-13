(** The request entries a transport runs after it has classified the
    request's authority (RFC-0512 D2).

    {!serve} is the entry of the single-user server: client and agent rate
    limits, the MCP origin and protocol-version checks, the workspace
    precondition, then the route table through
    {!Http_server_eio.Router.dispatch}. Its HTTP/1.1 adapter is
    {!http1_handler} and its HTTP/2 adapter is
    {!Server_h2_gateway.make_request_handler}. Both build an {!Http_reqd.t}
    and call {!serve}, so a route exists, is authenticated and answers the
    same way on both transports.

    {!serve_table} is the entry of the account server of a multi-account
    installation. It shares the admission of the authority and of the origin
    and the client address limit with {!serve}, and runs none of its other
    checks. Its adapters are {!http1_table_handler} and
    {!Server_h2_gateway.make_table_request_handler}. *)

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

val serve_table
  :  table:Server_account_table.t
  -> client_addr:Eio.Net.Sockaddr.stream
  -> Server_request_authority.classification
  -> Http_reqd.t
  -> unit
(** The entry of a server whose whole surface is its route table: the account
    server of a multi-account installation ({!Server_accounts}). The authority
    and the origin are admitted as {!serve} admits them, then the client
    address limit, then {!Server_account_table.dispatch}. It charges no agent
    bucket, runs no MCP check and no workspace precondition, and has no arm
    outside the router: a method or a path that the table does not hold is the
    405 or the 404 of the router, [OPTIONS] included. It takes the table and
    {!serve} takes a router, so neither is handed the routes of the other.

    A handler exception is answered as by {!serve}, except that the 500 says
    ["internal error"] and not the text of the exception, which can name a
    file of the server. The log has the text. Both entries use the same
    request-owner relay when the connection runs on the HTTP serving domain. *)

val health_probe_exempt : path:string -> Httpun.Request.t -> bool
(** Whether {!serve} leaves the request out of the client address limit and of
    the agent bucket: [/health/live] and [/health/ready] always, and [/health]
    while the request carries no credential header. A [/health] request that
    carries one makes the server check it, so it is counted like any other
    request. Every other path is counted. *)

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

val http1_table_handler
  :  trust_policy:Server_request_authority.trust_policy
  -> Server_account_table.t
  -> Eio.Net.Sockaddr.stream
  -> Httpun.Reqd.t Gluten.Reqd.t
  -> unit
(** {!http1_handler} over {!serve_table}. *)
