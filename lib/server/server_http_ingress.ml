module Http = Http_server_eio
module Common = Server_routes_http_common
module Transport = Server_mcp_transport_http

(* Issue #8403: derive probe exemptions from Server_health_paths SSOT so a
   renamed probe stays exempt from rate limits without a separate manual edit
   here. This path-only rule is for a table whose [/health] reads no
   credential (the account server) and for the agent bucket. *)
let is_rate_limit_exempt path =
  String.equal path Server_health_paths.health || Server_health_paths.is_public path
;;

(* HIGH-RISK-UNREVIEWED [H6]: a probe is exempt from the per-client limit
   while answering it reads no credential. [/health/live] and [/health/ready]
   never read one. The single-user [/health] reads the one a request carries
   ([Server_routes_http_runtime.health_handler]), so that request is counted
   like every other request that makes the server check one. *)
let health_probe_exempt ~path request =
  Server_health_paths.is_public path
  || (String.equal path Server_health_paths.health
      && not (Server_auth.request_carries_auth_credential request))
;;

let charges_agent_bucket (request : Httpun.Request.t) =
  Common.is_mcp_transport_request request
  || String.equal (Http.Request.path request) "/ws"
  ||
  match request.Httpun.Request.meth with
  | `GET | `HEAD -> false
  | _ -> true
;;

let respond_rate_limited reqd ~body ~rl_headers ~scope =
  let headers =
    Httpun.Headers.of_list
      (("content-type", "application/json")
       :: ("content-length", string_of_int (String.length body))
       :: rl_headers)
  in
  let acceptance =
    Http_reqd.try_respond_with_string
      reqd
      (Httpun.Response.create ~headers `Too_many_requests)
      body
  in
  Transport_metrics.record_http_rate_limit_response
    ~acceptance
    ~protocol:(Http_reqd.protocol reqd)
    ~scope
;;

(* True when the client address is over its limit and the request was refused
   with a 429 on [reqd]. *)
let try_client_rate_limit_block ~exempt ~client_addr reqd =
  if exempt
  then false
  else (
    let rl_key = Rate_limit.key_of_sockaddr client_addr in
    if Rate_limit.check_global ~key:rl_key
    then false
    else (
      respond_rate_limited
        reqd
        ~body:(Rate_limit.too_many_requests_body ())
        ~rl_headers:(Rate_limit.headers_global ~key:rl_key)
        ~scope:Transport_metrics.Client_ip;
      true))
;;

(* True when the request was refused with a 429 on [reqd]. *)
let try_rate_limit_block ~path ~client_addr ~request reqd =
  let exempt = health_probe_exempt ~path request in
  if try_client_rate_limit_block ~exempt ~client_addr reqd
  then true
  else if exempt || not (charges_agent_bucket request)
  then false
  else (
    match Server_auth.auth_token_from_request request with
    | None -> false
    | Some token ->
      (match Rate_limit.agent_key_of_token_or_name ~token () with
       | None -> false
       | Some agent_key ->
         if Rate_limit.check_agent_global ~key:agent_key
         then false
         else (
           respond_rate_limited
             reqd
             ~body:(Rate_limit.too_many_agent_requests_body ())
             ~rl_headers:(Rate_limit.headers_agent_global ~key:agent_key)
             ~scope:Transport_metrics.Agent;
           true)))
;;

(* True when the request failed the MCP origin or protocol-version check and
   the error response was sent on [reqd]. *)
let try_mcp_validation_block ~request_authority ~request ~protocol_version ~origin reqd =
  let is_mcp_transport = Common.is_mcp_transport_request request in
  if is_mcp_transport && not (Common.validate_origin ~request_authority request)
  then (
    let body =
      Server_routes_http_runtime.json_rpc_error Mcp_error_code.Invalid_request "Invalid origin"
    in
    let headers =
      Httpun.Headers.of_list
        ([ "content-length", string_of_int (String.length body)
         ; "content-type", "application/json"
         ; "vary", "Origin"
         ]
         @ Common.mcp_headers "-" protocol_version)
    in
    Http_reqd.respond_with_string reqd (Httpun.Response.create ~headers `Forbidden) body;
    true)
  else if is_mcp_transport
          && request.Httpun.Request.meth <> `OPTIONS
          && not (Transport.is_valid_protocol_version protocol_version)
  then (
    let body =
      Server_routes_http_runtime.json_rpc_error
        Mcp_error_code.Invalid_request
        "Unsupported protocol version"
    in
    let headers =
      Httpun.Headers.of_list
        (("content-length", string_of_int (String.length body))
         :: Common.json_headers "-" protocol_version origin)
    in
    Http_reqd.respond_with_string reqd (Httpun.Response.create ~headers `Bad_request) body;
    true)
  else false
;;

(* [GET /ws] (same-origin WebSocket upgrade + discovery) is owned by the route
   table ([Server_routes_http_routes_frontend] via [Server_route.ws_get]) and
   reached through [Http.Router.dispatch] below (RFC-0281). Board
   reads/reactions are owned by the typed route table: exact routes win over
   the board prefix route, and the prefix route resolves the bearer-bound
   reaction actor itself. *)
let dispatch_route ~router ~request ~path reqd =
  match request.Httpun.Request.meth, path with
  | `OPTIONS, _ -> Server_routes_http_runtime.options_handler request reqd
  | `DELETE, "/mcp" -> Common.handle_delete_mcp request reqd
  | `DELETE, "/mcp/managed" ->
    Common.handle_delete_mcp ~profile:Transport.Managed_agent request reqd
  | `DELETE, "/mcp/operator" ->
    Common.handle_delete_mcp ~profile:Transport.Operator_remote request reqd
  | _ -> Http.Router.dispatch router request reqd
;;

let log_late_response_failure ~context msg =
  Log.Http.warn "%s: response already unwritable; skipped late response (%s)" context msg
;;

let try_internal_error_response reqd msg =
  try Http.Response.internal_error msg reqd with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (match Http_reqd.Late_response.classify_write_failure exn with
     | Some failure_msg ->
       log_late_response_failure ~context:"http ingress internal_error" failure_msg
     | None ->
       Log.Http.warn "http ingress internal_error response failed: %s" (Printexc.to_string exn))
;;

let try_auth_config_error_response reqd =
  try Http.Response.text ~status:`Service_unavailable "Authentication configuration unavailable" reqd with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (match Http_reqd.Late_response.classify_write_failure exn with
     | Some failure_msg ->
       log_late_response_failure
         ~context:"http ingress auth configuration unavailable"
         failure_msg
     | None ->
       Log.Http.warn
         "http ingress auth configuration response failed: %s"
         (Printexc.to_string exn))
;;

(* What a failed handler gets depends on what it already sent. [answer]
   fits only a request with no response. Headers that went out cannot be
   taken back, so an open streaming response is cut where it stands: HTTP/2
   resets the stream, HTTP/1.1 stops the body and closes the connection.
   After a response the exception is only logged. *)
let handler_failed reqd exn ~answer =
  let late_or ~otherwise =
    match Http_reqd.Late_response.classify_write_failure exn with
    | Some failure_msg ->
      log_late_response_failure ~context:"http ingress request handler" failure_msg
    | None -> otherwise (Printexc.to_string exn)
  in
  match Http_reqd.response_state reqd with
  | Http_reqd.Not_started -> late_or ~otherwise:answer
  | Http_reqd.Streaming_open -> Http_reqd.report_exn reqd exn
  | Http_reqd.Answered ->
    late_or ~otherwise:(fun msg ->
      Log.Http.error "http ingress request handler raised after its response: %s" msg)
;;

let respond_request_authority_bad_request ~error_code ~message reqd =
  Http.Response.json_value
    ~status:`Bad_request
    (`Assoc [ "error_code", `String error_code; "error", `String message ])
    reqd
;;

(* Runs the steps of an admitted request and answers what they raise.
   [internal_error] is the body of the 500 for the exception text [msg]. *)
let answering_failures reqd ~internal_error steps =
  try steps () with
  (* Cancellation propagates through the connection switch without
     attempting a response from a cancelled handler. *)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Auth.Auth_config_error _ as exn ->
    handler_failed reqd exn ~answer:(fun _ -> try_auth_config_error_response reqd)
  | exn ->
    handler_failed reqd exn ~answer:(fun msg ->
      Log.Http.error "http ingress request handler raised: %s" msg;
      try_internal_error_response reqd (internal_error msg))
;;

(* Authority admission precedes rate limiting, auth, and routing so no
   credential I/O or URL projection can observe an untrusted Host or an
   ambiguous/malformed Origin field set. *)
let admitted ~routes ~client_addr ~request_authority request reqd =
  Server_request_authority.with_current request_authority (fun () ->
    let path = Http.Request.path request in
    if try_rate_limit_block ~path ~client_addr ~request reqd
    then ()
    else
      answering_failures reqd ~internal_error:Fun.id (fun () ->
        let session_id_for_version = Transport.get_session_id_any request in
        let protocol_version =
          Transport.get_protocol_version_for_session ?session_id:session_id_for_version request
        in
        let origin = Server_auth.get_origin request in
        if try_mcp_validation_block ~request_authority ~request ~protocol_version ~origin reqd
        then ()
        else
          Server_workspace_precondition.guard ~path request reqd ~admitted:(fun () ->
            dispatch_route ~router:routes ~request ~path reqd)))
;;

let table_internal_error = "internal error"

(* The whole surface is the table: no agent bucket, no MCP check, no
   workspace precondition, and no arm outside the router. The 500 of a handler
   that raised says nothing of the exception, whose text can name a file of
   the server; the log has it. *)
let admitted_to_table ~table ~client_addr ~request_authority request reqd =
  Server_request_authority.with_current request_authority (fun () ->
    let path = Http.Request.path request in
    if try_client_rate_limit_block ~exempt:(is_rate_limit_exempt path) ~client_addr reqd
    then ()
    else
      answering_failures
        reqd
        ~internal_error:(fun (_ : string) -> table_internal_error)
        (fun () -> Server_account_table.dispatch table request reqd))
;;

let serve_admitted ~admitted classification reqd =
  let request = Http_reqd.request reqd in
  match classification with
  | Server_request_authority.Missing ->
    respond_request_authority_bad_request
      ~error_code:"request_authority_missing"
      ~message:"request is missing its Host authority"
      reqd
  | Server_request_authority.Multiple ->
    respond_request_authority_bad_request
      ~error_code:"request_authority_multiple"
      ~message:"request contains more than one Host field"
      reqd
  | Server_request_authority.Malformed ->
    respond_request_authority_bad_request
      ~error_code:"request_authority_malformed"
      ~message:"request Host authority is malformed"
      reqd
  | Server_request_authority.Untrusted ->
    respond_request_authority_bad_request
      ~error_code:"request_authority_untrusted"
      ~message:"request Host is not a configured server identity"
      reqd
  | Server_request_authority.Single request_authority ->
    (match Server_auth.classify_request_origin ~request_authority request with
     | Server_auth.Multiple_origins ->
       respond_request_authority_bad_request
         ~error_code:"request_origin_multiple"
         ~message:"request contains more than one Origin field"
         reqd
     | Server_auth.Malformed_origin ->
       respond_request_authority_bad_request
         ~error_code:"request_origin_malformed"
         ~message:"request Origin is not one complete HTTP(S) serialized origin"
         reqd
     | Server_auth.Missing_origin | Server_auth.Single_origin _ ->
       admitted ~request_authority request reqd)
;;

(* Where a request is handled when its connection runs on another domain
   than the one that owns the server's root switch (the HTTP serving domain,
   RFC http-transport-runs-on-its-own-domain §3.3): the owner's queue and the
   scope its response is written under. A WebSocket route stays with its
   connection: the upgrade hands the socket to the handler. A [Serving] route
   stays there too: its registration says its handler may run beside the
   owner's (§3.4). A request no route matches is the owner's to refuse.
   [None] on the owner domain, which is every request while the serving
   domain is off. *)
let owner_relay ~stays_with_connection reqd =
  match Eio_context.owner_post () with
  | None -> None
  | Some post ->
    if stays_with_connection () then None
    else Option.map (fun sw -> sw, post) (Http_reqd.relay_scope reqd)
;;

(* The owner's queue drops what a task raises. [serve_admitted] answers its own
   failures; this is for the body and flush callbacks of a handler, which on
   the connection's domain would have raised into its fiber. *)
let reporting task () =
  try task () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Http.error
      "http ingress: a relayed request's callback raised: %s"
      (Printexc.to_string exn)
;;

(* The read mark of the request ([Pool_lane]) is bound to the connection's
   fiber and does not cross domains, so the handler's fiber takes it again. *)
let serve_owned ~stays_with_connection ~admitted classification reqd =
  match owner_relay ~stays_with_connection reqd with
  | None -> serve_admitted ~admitted classification reqd
  | Some (sw, post) ->
    let lane = Pool_lane.current () in
    let post task = post (reporting task) in
    Http_reqd.relay reqd ~sw ~post (fun relayed ->
      let handle () = serve_admitted ~admitted classification relayed in
      match lane with
      | Pool_lane.Read -> Pool_lane.with_read handle
      | Pool_lane.Background -> handle ())
;;

let serve ~routes ~client_addr classification reqd =
  let stays_with_connection () =
    match Http.Router.resolve routes (Http_reqd.request reqd) with
    | `Matched { Http.Router.handler = Http.Router.Ws _ | Http.Router.Serving _; _ } -> true
    | `Matched { Http.Router.handler = Http.Router.Owner _; _ }
    | `Method_not_allowed
    | `Not_found -> false
  in
  serve_owned
    ~stays_with_connection
    ~admitted:(admitted ~routes ~client_addr)
    classification
    reqd
;;

let serve_table ~table ~client_addr classification reqd =
  let stays_with_connection () =
    Server_account_table.stays_with_connection table (Http_reqd.request reqd)
  in
  serve_owned
    ~stays_with_connection
    ~admitted:(admitted_to_table ~table ~client_addr)
    classification
    reqd
;;

let http1 ~trust_policy ~serve client_addr gluten_reqd =
  let reqd = Http_reqd.of_gluten gluten_reqd in
  let request = Http_reqd.request reqd in
  serve
    ~client_addr
    (Server_request_authority.classify_http1_request ~trust_policy request)
    reqd
;;

let http1_handler ~trust_policy routes client_addr gluten_reqd =
  http1 ~trust_policy ~serve:(serve ~routes) client_addr gluten_reqd
;;

let http1_table_handler ~trust_policy table client_addr gluten_reqd =
  http1 ~trust_policy ~serve:(serve_table ~table) client_addr gluten_reqd
;;
