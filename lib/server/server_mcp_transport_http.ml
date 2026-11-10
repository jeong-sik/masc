(** Server_mcp_transport_http — SSE/POST MCP transport handler. *)

type tool_profile = Server_mcp_transport_http_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Seat

type runtime = Server_mcp_transport_http_types.runtime = {
  base_path : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  tool_allowed_in_profile : tool_profile -> string -> bool;
  handle_request :
    ?profile:tool_profile ->
    ?mcp_session_id:string ->
    ?otel_mcp_protocol_version:string ->
    ?otel_transport_context:Otel_dispatch_hook.transport_context ->
    ?auth_token:string ->
    ?internal_keeper_runtime:bool ->
    string ->
    Yojson.Safe.t;
  clear_resource_subscriptions_for_session : string -> unit;
}

let scope_challenge_cors_headers ~request_authority request =
  match Server_auth.public_read_cors_origin_opt ~request_authority request with
  | None -> [ "vary", "Origin" ]
  | Some origin ->
      Server_auth.cors_headers origin
      |> List.map (fun (name, value) ->
           if String.equal name "access-control-expose-headers" then
             name, value ^ ", WWW-Authenticate"
           else name, value)

let tool_allowed_in_profile state profile name =
  Mcp_server_eio_tool_profile.tool_allowed_in_profile state profile name

include Server_mcp_transport_http_protocol
include Server_mcp_transport_http_conn
include Server_mcp_transport_http_respond
include Server_mcp_transport_http_agui

(* RFC-0100 PR-2: chunked first-flush variant of [Http_reqd.respond_with_string].
   Writes [body] via [Http_reqd.respond_with_streaming] so the response
   uses [Transfer-Encoding: chunked] framing instead of
   [Content-Length: N]. Body bytes and headers (other than transfer-encoding /
   content-length) are byte-identical to the non-chunked form, so well-behaved
   JSON clients are unaffected.

   The 50 ms first-flush budget is implicit at PR-2 — current sync code
   paths compute the body in well under 50 ms, so the first (and only)
   chunk flushes immediately. The placeholder-stub flow for slow paths
   is RFC-0100 PR-3's auto-upgrade work, not this PR.

   The same late-write guard as [Http_reqd.respond_with_string]: a request
   that can no longer take a response raises [Failure], logged at WARN. *)
let safe_respond_chunked reqd response body =
  try
    let writer = Http_reqd.respond_with_streaming reqd response in
    Http_reqd.Body_writer.write_string writer body ;
    Http_reqd.Body_writer.close writer
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked skipped (reqd invalid state; \
         2026-05-05 AGENT_CORE cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked unexpected exception: %s"
        (Printexc.to_string exn)

let body_jsonrpc_method = Server_mcp_transport_http_headers.body_jsonrpc_method

let sse_prime_event = Server_mcp_transport_http_headers.sse_prime_event

let sse_ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s
let ping_interval_override = Atomic.make None
let disconnect_test_hook = ref (fun _ -> ())
let ping_interval () =
  match Atomic.get ping_interval_override with
  | Some seconds -> seconds
  | None -> sse_ping_interval_s

let post_sse_keepalive_interval_s = Float.max 0.1 sse_ping_interval_s

let body_jsonrpc_id body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> List.assoc_opt "id" fields
    | _ -> None
  with Yojson.Json_error _ -> None

(* RFC-0100 PR-3: extract [params.name] from a [tools/call] body for
   streaming-registry lookup. Returns [None] when the body is malformed,
   not a [tools/call], or missing [params.name]. *)
let body_tools_call_name body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> (
        match List.assoc_opt "params" fields with
        | Some (`Assoc params) -> (
            match List.assoc_opt "name" params with
            | Some (`String name) -> Some name
            | _ -> None)
        | _ -> None)
    | _ -> None
  with Yojson.Json_error _ -> None

let session_cookie_headers = Server_mcp_transport_http_headers.session_cookie_headers

let sse_headers = Server_mcp_transport_http_headers.sse_headers

let sse_stream_headers = Server_mcp_transport_http_headers.sse_stream_headers

let stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version =
  Httpun.Headers.of_list
    ([
        ("content-type", Http_negotiation.sse_content_type);
        ("cache-control", "no-cache");
        ("connection", "close");
        ("x-accel-buffering", "no");
      ]
      @ session_cookie_headers protocol_version session_id
      @ mcp_headers session_id protocol_version
      @ deps.cors_headers origin)

(* A tools/call POST stream stays out of the SSE registry. Only its handler
   and keepalive fiber write it, both on the connection's domain, so it uses
   the response directly. *)
let send_post_sse ~session_id response frame =
  match Server_sse_response.send response frame with
  | Written ->
    Sse.touch session_id;
    true
  | Closed | Stalled -> false

let stream_post_sse_start ~deps ~origin ~session_id ~protocol_version ~clock
    reqd =
  let headers =
    stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version
  in
  let response =
    Server_sse_response.respond ~clock ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s reqd
      (Httpun.Response.create ~headers `OK)
  in
  if not (send_post_sse ~session_id response (sse_prime_event ())) then
    Log.Server.debug "SSE prime send failed for session %s" session_id;
  response

let spawn_post_sse_keepalive ~sw ~clock ~session_id response =
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        if not (Server_sse_response.is_closed response) then (
          Eio.Time.sleep clock post_sse_keepalive_interval_s;
          if not (Server_sse_response.is_closed response)
             && not (send_post_sse ~session_id response ": keepalive\n\n")
          then
            Log.Server.debug "SSE keepalive send failed for session %s"
              session_id;
          loop ())
      in
      try loop ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.warn "SSE keepalive failed for session %s: %s" session_id
          (Printexc.to_string exn);
        Server_sse_response.close response)

let stream_post_sse_finish response = Server_sse_response.close response

let stream_post_sse_json ~session_id response (json : Yojson.Safe.t) =
  if not (send_post_sse ~session_id response
            (Sse.format_event ~event_type:"message" (Yojson.Safe.to_string json)))
  then
    Log.Server.debug "SSE json send failed for session %s" session_id

(* subscriptions/listen (2026-07-28) replaces the GET endpoint: one long-lived
   POST whose response body is the notification stream. Unlike the tools/call
   streaming path it does not end when a result is written -- the JSON-RPC
   response is the graceful-closure signal, sent when the server ends the
   subscription, and a stream that just drops carries none. *)
let body_is_subscriptions_listen body_str =
  match body_jsonrpc_method body_str with
  | Some ("subscriptions/listen", true) -> true
  | _ -> false

(* The seat opens no server stream. Both kinds carry the workspace: the GET
   agent stream receives task events through [Sse.broadcast], and a listen
   stream carries resources/updated for workspace resources. *)
let profile_opens_server_stream = function
  | Full | Managed_agent | Operator_remote -> true
  | Seat -> false

(* A listen body on an endpoint without a stream is not intercepted: it goes to
   the dispatcher like any other method, and the seat's dispatcher refuses it. *)
let serves_subscriptions_listen ~profile body_str =
  profile_opens_server_stream profile && body_is_subscriptions_listen body_str

let body_jsonrpc_params body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields -> List.assoc_opt "params" fields
  | _ | (exception Yojson.Json_error _) -> None

let serve_subscriptions_listen ~deps ~origin ~session_id ~protocol_version
      ~clock ~body_str reqd =
  match body_jsonrpc_id body_str with
  (* JSON-RPC 2.0 requires a request id and 2026-07-28 forbids a null one, so a
     listen request without one has no subscription identity to give its
     notifications. *)
  | None | Some `Null ->
    let body =
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request
        ~message:"subscriptions/listen requires a non-null request id"
    in
    let headers =
      Httpun.Headers.of_list
        (("content-length", string_of_int (String.length body))
         :: json_headers ~deps session_id protocol_version origin)
    in
    Http_reqd.respond_with_string reqd
      (Httpun.Response.create ~headers `Bad_request)
      body
  | Some subscription_id ->
    Server_mcp_listen_stream.serve
      ~clock
      ~ping_interval_s:post_sse_keepalive_interval_s
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~max_queued_events:Sse.stream_capacity
      ~subscription_id
      ~filter:
        (Mcp_subscriptions.honoured_filter
           (Mcp_transport_protocol.subscription_filter_of_params
              (body_jsonrpc_params body_str)))
      ~headers:(stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version)
      reqd

let should_stream_post_tools_call request body_str accept_mode =
  should_use_sse_for_body request body_str accept_mode
  && not force_json_response
  && not (request_force_json_response request)
  && (not (request_uses_stateless_protocol request body_str)
      || (not (Mcp_transport_protocol.request_has_continuation_fields
                 (body_jsonrpc_params body_str))
          && Result.is_ok
               (Masc.Mcp_server_eio_call_request.decode (body_jsonrpc_params body_str))))
  &&
  match body_jsonrpc_method body_str with
  | Some ("tools/call", true) -> (
      (* RFC-0100 PR-3: the [tools/call] request only upgrades to SSE
         framing when the named tool is on the streaming registry
         ([Server_mcp_streaming_tools]). Tools outside the registry stay on
         the RFC-0100 PR-2 chunked-JSON default. Returns [false] when
         [params.name] is missing — a malformed body never triggers the
         streaming branch. *)
      match body_tools_call_name body_str with
      | Some name -> Server_mcp_streaming_tools.is_streaming_capable name
      | None -> false)
  | _ -> false

let body_with_canonical_http_actor ~base_path ~auth_token request body_str =
  match body_jsonrpc_method body_str with
  | Some ("tools/call", _) ->
      let actor = Server_auth.dashboard_actor_for_request ~base_path request in
      Server_mcp_actor_injection.reduce ~actor ~auth_token body_str
  | _ ->
      (* Only tool arguments carry a caller identity. HTTP admission and
         protocol authorization still run for every request. *)
      body_str

(* Auth-reject metric/log endpoint labels. Built on [profile_label]
   so the label vocabulary cannot drift from the session module's
   profile naming. *)
let post_endpoint_label profile = "POST " ^ profile_label profile
let get_endpoint_label profile = "GET " ^ profile_label profile
let delete_endpoint_label profile = "DELETE " ^ profile_label profile

(* The OpenTelemetry transport of the connection a request came on. *)
let transport_context_of_reqd reqd =
  Otel_dispatch_hook.http_transport_context
    ~protocol_version:(Transport_metrics.http_protocol_version (Http_reqd.protocol reqd))

let handle_post_mcp ~deps ?(profile = Full) request reqd =
  let request_authority = Server_request_authority.current_exn () in
  (* Readiness gate: reject before session/auth if server state is not ready *)
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  (* The admitted authority is a fiber-local binding whose dynamic extent is the
     router dispatch (bin/main_eio.ml for HTTP/1.1, server_h2_gateway for h2c).
     Everything below runs from the async body callback and from a fiber forked
     onto runtime.sw, both outside that extent, so read it here and carry the
     value. *)
  let expected_resource =
    Server_oauth_metadata.resource request_authority
  in
  let session_id_opt =
    if Server_mcp_transport_http_headers.header_selects_per_request_protocol request
    then None
    else get_session_id_any request
  in
  let session_id =
    match session_id_opt with
    | Some sid -> sid
    | None -> Mcp_session.generate ()
  in
  let context =
    Server_mcp_request_context.make ~session_id_opt
      ~generated_session_id:session_id
      ~auth_token:(deps.auth_token_from_request request)
      ~protocol_version:(get_protocol_version_for_session ~session_id request)
      ~origin:(deps.get_origin request) ~base_path:(deps.get_base_path ())
  in
  let session_id = context.session_id in
  let auth_token = context.auth_token in
  let protocol_version = context.protocol_version in
  let origin = context.origin in
  let base_path = context.base_path in
  let auth_started = Mtime_clock.elapsed_ns () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        deps.verify_mcp_auth ~base_path request
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
    | Seat ->
        deps.verify_seat_mcp_auth ~base_path request
  in
  let auth_ms =
    Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) auth_started) /. 1e6
  in
  let open Result.Syntax in
  ignore (
    let* () =
      match validate_mcp_session_profile ~profile session_id with
      | Ok () -> Ok ()
      | Error msg ->
          let body =
            Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: json_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Conflict in
          Http_reqd.respond_with_string reqd response body;
          Error ()
    in
    let* () =
      match auth_result with
      | Ok () -> Ok ()
      | Error failure ->
          respond_mcp_auth_error
            ~deps
            ~request_authority
            ~endpoint:(post_endpoint_label profile)
            request
            reqd
            ~session_id
            ~protocol_version
            failure;
          Error ()
    in
    let* () =
      match validate_protocol_version_continuity ~session_id request with
      | Ok () -> Ok ()
      | Error rejection ->
          Http.Request.read_body_async reqd (fun request_body ->
            let body =
              match Server_mcp_transport_http_headers.validate_2026_request_headers
                      request request_body with
              | Error header_error ->
                Server_mcp_transport_http_headers.header_rejection_body
                  request_body header_error
              | Ok () ->
                protocol_version_rejection_body_for_request ~request_body rejection
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps session_id protocol_version origin)
            in
            let response = Httpun.Response.create ~headers `Bad_request in
            Http_reqd.respond_with_string reqd response body);
          Error ()
    in
    Ok (Http.Request.read_body_async reqd (fun body_str ->
      ignore (
      let* post_context =
        match
          Server_mcp_request_context.decide_post_body ~request ~context
            ~session_is_known:(is_known_session session_id)
            body_str
        with
        | Ok decision -> Ok decision
        | Error (Server_mcp_request_context.Session_required msg) ->
            let body =
              Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
              |> correlate_error_body_to_request ~request_body:body_str
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps session_id protocol_version
                     origin)
            in
            Http_reqd.respond_with_string reqd
              (Httpun.Response.create ~headers `Bad_request)
              body;
            Error ()
        | Error (Server_mcp_request_context.Unknown_session msg) ->
            let new_session_id = Mcp_session.generate () in
            let body =
              Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
              |> correlate_error_body_to_request ~request_body:body_str
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps new_session_id protocol_version
                     origin)
            in
            Http_reqd.respond_with_string reqd
              (Httpun.Response.create ~headers `Not_found)
              body;
            Error ()
        | Error (Server_mcp_request_context.Invalid_accept msg) ->
            let body =
              Mcp_error_code.jsonrpc_error_body Invalid_request ~message:msg
              |> correlate_error_body_to_request ~request_body:body_str
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps session_id protocol_version origin)
            in
            let response = Httpun.Response.create ~headers `Bad_request in
            Http_reqd.respond_with_string reqd response body;
            Error ()
        | Error (Server_mcp_request_context.Header_mismatch rejection) ->
            let body =
              Server_mcp_transport_http_headers.header_rejection_body body_str
                rejection
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps session_id protocol_version origin)
            in
            let response = Httpun.Response.create ~headers `Bad_request in
            Http_reqd.respond_with_string reqd response body;
            Error ()
      in
      let stateless_request = request_uses_stateless_protocol request body_str in
      if not stateless_request then (
        let otel_transport_context = transport_context_of_reqd reqd in
        remember_mcp_profile ~otel_transport_context session_id profile);
      let accept_mode = post_context.accept_mode in
      let* runtime =
        match deps.get_runtime_result () with
        | Ok r -> Ok r
        | Error msg ->
            respond_mcp_error ~code:Mcp_error_code.Internal_error ~deps
              ~request_authority request reqd ~session_id ~protocol_version msg;
            Error ()
      in
      let* () =
        match
          if Server_oauth_metadata.loopback_authority request_authority then
            Auth_oauth.with_expected_resource expected_resource (fun () ->
              Server_oauth_step_up.required_scope ~base_path ~auth_token
                ~allowed_tool:(runtime.tool_allowed_in_profile profile)
                ~body:body_str)
          else None
        with
        | None -> Ok ()
        | Some scope ->
            let auth_cors =
              scope_challenge_cors_headers ~request_authority request
            in
            let deps = { deps with cors_headers = (fun _ -> auth_cors) } in
            respond_mcp_error
              ~extra_headers:
                [ ( "www-authenticate"
                  , Server_oauth_metadata.insufficient_scope_challenge
                      request_authority scope ) ]
              ?id:(body_jsonrpc_id body_str)
              ~code:Mcp_error_code.Insufficient_scope ~deps ~request_authority
              request reqd ~session_id ~protocol_version
              (Printf.sprintf "This tool needs the OAuth scope %s."
                 (Auth_oauth.scope_to_string scope));
            Error ()
      in
      let sw = runtime.sw in
      let clock = runtime.clock in
      Ok (Eio.Fiber.fork ~sw (fun () ->
                            (* Only immutable auth duration crosses the fiber boundary.
                               Buffered responses report phases, not total request time. *)
                            let timing = Server_timing.create () in
                            Server_timing.record_ms timing Mcp_http_auth auth_ms;
                            let timed_headers headers =
                              Httpun.Headers.of_list
                                (Server_timing.extra_header timing @ headers)
                            in
                            let otel_transport_context = transport_context_of_reqd reqd in
                            let response_protocol_version =
                              match protocol_version_from_body body_str with
                              | Some v -> v
                              | None ->
                                  get_protocol_version_for_session ~session_id request
                            in
                            let wants_streaming_post =
                              should_stream_post_tools_call request body_str
                                accept_mode
                            in
                            let response_id = body_jsonrpc_id body_str in
                            let inline_sse : Server_sse_response.t option ref = ref None in
                            try
                              if wants_streaming_post then (
                                let response =
                                  stream_post_sse_start ~deps ~origin ~session_id
                                    ~protocol_version:response_protocol_version
                                    ~clock reqd
                                in
                                inline_sse := Some response;
                                spawn_post_sse_keepalive ~sw ~clock ~session_id
                                  response);
                              let response_json =
                                Auth_oauth.with_expected_resource expected_resource
                                  (fun () ->
                                    let body_with_agent, internal_keeper_runtime =
                                      Server_timing.measure timing Mcp_identity (fun () ->
                                        let body_with_agent =
                                          body_with_canonical_http_actor ~base_path
                                            ~auth_token request body_str
                                        in
                                        let internal_keeper_runtime =
                                          Server_auth.is_verified_internal_keeper_request
                                            ~base_path request
                                        in
                                        body_with_agent, internal_keeper_runtime)
                                    in
                                    Server_timing.measure timing Mcp_dispatch (fun () ->
                                      runtime.handle_request ?auth_token ~profile
                                        ?mcp_session_id:
                                          (if stateless_request then None
                                           else Some session_id)
                                        ~otel_mcp_protocol_version:protocol_version
                                        ~otel_transport_context
                                        ~internal_keeper_runtime body_with_agent))
                              in
                              remember_protocol_version_if_initialize_succeeded
                                ~otel_transport_context
                                session_id
                                ~request_body:body_str
                                ~response_json;
                              let protocol_version =
                                get_protocol_version_for_session ~session_id request
                              in
                              let wants_sse =
                                should_use_sse_for_body request body_str accept_mode
                                && not force_json_response
                                && not (request_force_json_response request)
                              in
                              if serves_subscriptions_listen ~profile body_str
                                 && (match response_json with
                                     | `Assoc fields -> List.mem_assoc "result" fields
                                     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
                                     | `String _ | `List _ -> false)
                              then
                                serve_subscriptions_listen ~deps ~origin
                                  ~session_id
                                  ~protocol_version:response_protocol_version
                                  ~clock ~body_str reqd
                              else if wants_streaming_post then
                                match !inline_sse with
                                | Some response ->
                                    if response_json <> `Null then
                                      stream_post_sse_json ~session_id response
                                        response_json;
                                    stream_post_sse_finish response
                                | None -> ()
                              else match
                                Server_mcp_transport_http_headers
                                .modern_response_http_error_status
                                  ~request ~body_str response_json
                              with
                              | Some status ->
                                let body = Yojson.Safe.to_string response_json in
                                let headers =
                                  timed_headers
                                    (("content-length", string_of_int (String.length body))
                                     :: json_headers ~deps session_id protocol_version origin)
                                in
                                Http_reqd.respond_with_string reqd
                                  (Httpun.Response.create ~headers status) body
                              | None when wants_sse ->
                                (match response_json with
                                | `Null ->
                                    let headers =
                                      timed_headers
                                        (("content-length", "0")
                                        :: mcp_headers session_id protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    Http_reqd.respond_with_string reqd response ""
                                | json when Mcp_error_code.is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      timed_headers
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Bad_request
                                    in
                                    Http_reqd.respond_with_string reqd response
                                      body
                                | json ->
                                    let event =
                                      Sse.format_event ~event_type:"message"
                                        (Yojson.Safe.to_string json)
                                    in
                                    let body = sse_prime_event () ^ event in
                                    let headers =
                                      timed_headers
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: sse_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    Http_reqd.respond_with_string reqd response
                                      body)
                              | None ->
                                match response_json with
                                | `Null ->
                                    let headers =
                                      timed_headers
                                        (("content-length", "0")
                                        :: mcp_headers session_id protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    Http_reqd.respond_with_string reqd response ""
                                | json when Mcp_error_code.is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      timed_headers
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Bad_request
                                    in
                                    Http_reqd.respond_with_string reqd response
                                      body
                                | json ->
                                    (* RFC-0100 PR-2: chunked first-flush.
                                       Body bytes + Content-Type identical
                                       to pre-PR behaviour; only the
                                       framing changes (content-length →
                                       transfer-encoding: chunked).
                                       Well-behaved JSON clients are
                                       unaffected; this opt-out can be
                                       re-introduced via env knob if a
                                       legacy client surface needs it. *)
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      timed_headers
                                        (("transfer-encoding", "chunked")
                                        :: json_headers ~deps session_id
                                            protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_chunked reqd response body
                            with
                            | Eio.Cancel.Cancelled _ as e ->
                                (* A cancelled call still ends its stream, so
                                   the client sees the end instead of an open
                                   response. Closing does not suspend. *)
                                Option.iter stream_post_sse_finish !inline_sse;
                                raise e
                            | exn ->
                                (match !inline_sse with
                                | Some response ->
                                    stream_post_sse_json ~session_id response
                                      (error_body ~code:Mcp_error_code.Internal_error ?id:response_id
                                         ("Internal error: "
                                        ^ Printexc.to_string exn));
                                    stream_post_sse_finish response
                                | None ->
                                    let protocol_version =
                                      get_protocol_version_for_session ~session_id
                                        request
                                    in
                                    respond_mcp_error ~code:Mcp_error_code.Internal_error
                                      ~deps ~request_authority request reqd ~session_id
                                      ~protocol_version
                                      ("Internal error: "
                                     ^ Printexc.to_string exn))))))))

let handle_get_mcp ~deps ?(profile = Full) ?(sse_kind = Sse.Agent_stream)
    request reqd =
  let request_authority = Server_request_authority.current_exn () in
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let origin = deps.get_origin request in
  let requested_session_id = get_session_id_any request in
  let session_id = Mcp_session.get_or_generate requested_session_id in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let machine =
    match Server_machine_spectator.machine_of_request_target request.target with
    | Error _ as error -> error
    | Ok machine ->
        (match machine, sse_kind with
         | Some _, (Sse.Agent_stream | Sse.Presence) ->
             Error "the machine query requires an observer stream"
         | None, (Sse.Agent_stream | Sse.Presence) -> Ok None
         | (Some _ | None), Sse.Observer -> Ok machine)
  in
  let browser =
    match Server_browser_spectator.scope_of_request_target request.target with
    | Error _ as error -> error
    | Ok browser ->
        (match browser, sse_kind with
         | Some _, (Sse.Agent_stream | Sse.Presence) ->
             Error "a browser query requires an observer stream"
         | None, (Sse.Agent_stream | Sse.Presence) -> Ok None
         | (Some _ | None), Sse.Observer -> Ok browser)
  in
  let play =
    match Server_play_room_events.room_scope_of_request_target request.target with
    | Error _ as error -> error
    | Ok play ->
        (match play, sse_kind with
         | Some _, (Sse.Agent_stream | Sse.Presence) ->
             Error "a play query requires an observer stream"
         | None, (Sse.Agent_stream | Sse.Presence) -> Ok None
         | (Some _ | None), Sse.Observer -> Ok play)
  in
  match machine, browser, play with
  | Error detail, _, _ | _, Error detail, _ | _, _, Error detail ->
      respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
        ~request_authority request reqd ~session_id ~protocol_version detail
  | Ok (Some _), Ok _, Ok _ when Result.is_error (deps.get_runtime_result ()) ->
      respond_not_ready ~deps request reqd
  | Ok machine, Ok browser, Ok play ->
  let observer_scope =
    match sse_kind with
    | Sse.Observer ->
      Option.map (fun state -> state, Mcp_server.workspace_scope state)
        (deps.get_server_state ())
    | Sse.Agent_stream | Sse.Presence -> None
  in
  let scope_is_current () =
    match sse_kind, observer_scope with
    | Sse.Observer, Some (state, scope) ->
      Option.exists (fun current -> current == state) (deps.get_server_state ())
      && Mcp_server.Workspace_scope_epoch.equal scope.epoch
           (Mcp_server.workspace_scope state).epoch
    | Sse.Observer, None -> false
    | (Sse.Agent_stream | Sse.Presence), _ -> true
  in
  let base_path = match observer_scope with
    | Some (_, scope) -> scope.config.base_path
    | None -> deps.get_base_path ()
  in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        (match sse_kind with
         | Sse.Observer | Sse.Presence ->
             deps.verify_mcp_observer_stream_auth ~base_path request
         | Sse.Agent_stream ->
             deps.verify_mcp_auth ~base_path request)
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
    (* No route reaches this arm: /mcp/play registers no GET, since
       [profile_opens_server_stream Seat] is false. *)
    | Seat ->
        Error
          { Server_mcp_transport_http_types.message =
              "the seat endpoint offers no server stream"
          ; auth_error_code = None
          }
  in
  let last_event_id = Server_mcp_transport_http_headers.get_last_event_id request in
  match validate_mcp_session_profile ~profile session_id with
  | Error msg ->
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length msg))
          :: json_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Http_reqd.respond_with_string reqd response msg
  | Ok () -> (
      match validate_protocol_version_continuity ~session_id request with
      | Error rejection ->
          let body = protocol_version_rejection_body rejection in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: json_headers ~deps session_id protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Http_reqd.respond_with_string reqd response body
      | Ok () ->
      (match auth_result with
      | Error failure ->
          respond_mcp_auth_error
            ~deps
            ~request_authority
            ~endpoint:(get_endpoint_label profile)
            request
            reqd
            ~session_id
            ~protocol_version
            failure
      | Ok () ->
          (match last_event_id with
          | Error error ->
              respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                ~request_authority request reqd ~session_id ~protocol_version
                (Server_mcp_transport_http_headers.last_event_id_error_to_string
                   error)
          | Ok last_event_id ->
      let admission =
        match sse_kind, observer_scope with
        | Sse.Observer, None -> Error `Not_ready
        | Sse.Observer, Some (_, scope) ->
          (match Server_auth.validate_read_workspace_precondition
                   ~config:scope.config request with
           | Ok Server_auth.Workspace_read_unbound -> Ok []
           | Ok Server_auth.Workspace_read_matched ->
             Ok [Workspace.read_precondition_admission_header]
           | Error error -> Error (`Workspace error))
        | (Sse.Agent_stream | Sse.Presence), _ -> Ok []
      in
      let refuse_workspace error =
        let json, status = Server_auth.read_workspace_precondition_error_response error in
        Http_server_eio.Response.json_value ~status ~request
          ~extra_headers:(deps.cors_headers origin) json reqd
      in
      (match admission with
       | Error `Not_ready -> respond_not_ready ~deps request reqd
       | Error (`Workspace error) -> refuse_workspace error
       | Ok _ when not (scope_is_current ()) ->
         refuse_workspace Workspace.Workspace_precondition_failed
       | Ok admission_headers ->
      let observer_handshake, last_event_id =
        match sse_kind with
        | Sse.Observer ->
            (* Replay is retained by process and base path. A same-path
               workspace replacement must still reset the previous cursor. *)
            let instance_id =
              match observer_scope with
              | Some (_, scope) -> Server_observer_scope.instance_id scope
              | None -> Build_identity.runtime_instance_id
            in
            let handshake, cursor =
              Sse_wire.negotiate_observer
                ~instance_id
                ~current_event_id:(Sse.current_id ())
                ~headers:(Httpun.Headers.to_list request.headers) ~last_event_id
            in
            Some handshake, cursor
        | Sse.Agent_stream | Sse.Presence -> None, last_event_id
      in
      let observer_instance_id = Option.map
          (fun handshake -> handshake.Sse_wire.instance_id) observer_handshake in
      let standalone_observer_instance =
        match sse_kind, requested_session_id, observer_instance_id with
        | Sse.Observer, None, Some instance -> Some instance
        | Sse.Observer, None, None
        | Sse.Observer, Some _, _
        | (Sse.Agent_stream | Sse.Presence), _, _ -> None
      in
      let otel_transport_context = transport_context_of_reqd reqd in
      (match standalone_observer_instance with
       | Some _ -> ()
       | None -> remember_mcp_profile ~otel_transport_context session_id profile);
      let token =
        match sse_kind with
        | Sse.Observer | Sse.Presence ->
            Server_auth.observer_sse_auth_token_from_request request
        | Sse.Agent_stream ->
            Server_auth.auth_token_from_request request
      in
      let auth = { Sse.config = base_path; token } in
      let session_guard = match standalone_observer_instance with
        | Some _ -> Ok () (* Charged with the validated actor just before publication. *)
        | None -> check_sse_connect_guard session_id
      in
      (match session_guard with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~session_id:(Some session_id) ~protocol_version
            ~reason ~retry_after_s reqd
      | Ok () ->
          if Option.is_some last_event_id then
            Transport_metrics.inc_sse_reconnect ();
          (match standalone_observer_instance with
           | Some _ -> ()
           | None -> ensure_sse_backing_session_for_known_transport_session
               ~transport_session_id:session_id ~sse_session_id:session_id);
          let expected_resource =
            Server_oauth_metadata.resource request_authority
          in
          let owned_info = Atomic.make None in
          let disconnected = Atomic.make false in
          let play_registration = Atomic.make None in
          let previous_cleanup = Atomic.make None in
          let previous_cleanup_done = Atomic.make false in
          let cleanup_previous () =
            if not (Atomic.get previous_cleanup_done) then
              match Atomic.get previous_cleanup with
              | Some previous when Atomic.compare_and_set previous_cleanup_done false true ->
                (match previous.Sse.on_disconnect with
                 | Some hook -> hook ()
                 | None -> ())
              | Some _ | None -> ()
          in
          let disconnect_play () =
            Option.iter (fun (client, scope) ->
              match Server_play_room_events.disconnect ~base_path
                ~agent_name:client.Sse.agent_name ~role:client.Sse.role ~scope
                ~sse_client_id:client.Sse.id with
              | Ok () -> ()
              | Error error ->
                Log.Server.warn "Play room disconnect failed for %s: %s"
                  session_id (Play_room.error_message error))
              (Atomic.get play_registration)
          in
          let on_disconnect () =
            Eio.Cancel.protect (fun () ->
              Atomic.set disconnected true;
              !disconnect_test_hook (Atomic.get owned_info);
              Fun.protect
                ~finally:(fun () ->
                  disconnect_play ();
                  cleanup_previous ())
                (fun () -> Option.iter stop_sse_conn_if_current (Atomic.get owned_info)));
            Eio.Fiber.check ()
          in
          let renew_play () =
            Option.iter (fun (client, scope) ->
              match Server_play_room_events.renew ~base_path
                ~agent_name:client.Sse.agent_name ~role:client.Sse.role ~scope
                ~sse_client_id:client.Sse.id with
              | Ok () -> ()
              | Error error ->
                Log.Server.warn "Play room renewal failed for %s: %s"
                  session_id (Play_room.error_message error))
              (Atomic.get play_registration)
          in
          let with_play_presence (previous : Sse.client option) (client : Sse.client) body =
            Atomic.set previous_cleanup previous;
            Atomic.set play_registration
              (Option.map (fun scope -> client, scope) play);
            if Atomic.get disconnected then begin
              Sse.unregister_if_current session_id client.id;
              stop_sse_session_before ~client_id:client.id session_id;
              cleanup_previous ();
              respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                ~request_authority request reqd ~session_id ~protocol_version
                "Observer disconnected before publication"
            end else
            match play with
            | Some scope ->
              (match Server_play_room_events.connect ~base_path
                ~agent_name:client.Sse.agent_name ~role:client.Sse.role ~scope
                ~sse_client_id:client.Sse.id with
               | Ok Server_play_room_events.Connected ->
                 if Atomic.get disconnected then begin
                   disconnect_play ();
                   Sse.unregister_if_current session_id client.id;
                   stop_sse_session_before ~client_id:client.id session_id;
                   cleanup_previous ();
                   respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                     ~request_authority request reqd ~session_id ~protocol_version
                     "Observer disconnected before publication"
                 end else begin
                   cleanup_previous ();
                   stop_sse_session_before ~client_id:client.id session_id;
                   body ()
                 end
               | Ok Server_play_room_events.Stale ->
                 Sse.unregister_if_current session_id client.id;
                 respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                   ~request_authority request reqd ~session_id ~protocol_version
                   "Play observer was replaced by a newer client"
               | Error error ->
                 Sse.unregister_if_current session_id client.id;
                 stop_sse_session_before ~client_id:client.id session_id;
                 cleanup_previous ();
                 respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                   ~request_authority request reqd ~session_id ~protocol_version
                   (Play_room.error_message error))
            | None ->
              cleanup_previous ();
              stop_sse_session_before ~client_id:client.id session_id;
              body ()
          in
          (match
             Auth_oauth.with_expected_resource expected_resource (fun () ->
               let last_event_id = Option.value ~default:0 last_event_id in
               match standalone_observer_instance with
               | Some observer_instance_id ->
                 Sse.register_standalone_observer_with_client ~auth
                    ~observer_instance_id
                    ~admit:(fun credential ->
                      check_standalone_observer_connect_guard ~observer_instance_id ~credential)
                    ~on_disconnect session_id ~last_event_id
               | None ->
                 Sse.register_with_client ~kind:sse_kind ~auth ?observer_instance_id
                    ~on_disconnect session_id ~last_event_id
                  |> Result.map_error (fun error -> Sse.Credential_refused error))
           with
            | Error (Sse.Admission_refused (reason, retry_after_s)) ->
                respond_sse_rate_limited ~deps ~origin ~session_id:None ~protocol_version
                  ~reason ~retry_after_s reqd
            | Error (Sse.Credential_refused reg_err) ->
               let msg = Sse.registration_error_to_string reg_err in
               Log.Server.warn "%s" msg;
               (match reg_err with
                | Sse.Registration_stale _ -> ()
                | Sse.Missing_token | Sse.Invalid_token _ | Sse.Token_expired _
                | Sse.Auth_lookup_error _ | Sse.Unknown_session _ | Sse.Session_expired _
                | Sse.Session_owner_mismatch _ -> stop_sse_session session_id);
               respond_sse_register_error ~deps ~origin ~protocol_version reqd msg
           | Ok (client, previous, _) when not (scope_is_current ()) ->
              Atomic.set previous_cleanup previous;
              Sse.unregister_if_current session_id client.id;
              stop_sse_session_before ~client_id:client.id session_id;
              cleanup_previous ();
              refuse_workspace Workspace.Workspace_precondition_failed
           | Ok (client, previous, _) when sse_kind = Sse.Observer && not (deps.is_ready ()) ->
              Atomic.set previous_cleanup previous;
              Sse.unregister_if_current session_id client.id;
              stop_sse_session_before ~client_id:client.id session_id;
              cleanup_previous ();
              respond_not_ready ~deps request reqd
           | Ok (client, previous, evicted) ->
              with_play_presence previous client (fun () ->
              let client_id = client.id in
              let event_stream = client.event_stream in
              let attested_runtime =
                match sse_kind, admission_headers with
                | Sse.Observer, [receipt]
                  when receipt = Workspace.read_precondition_admission_header ->
                    Some (deps.get_runtime_result ())
                | (Sse.Observer | Sse.Agent_stream | Sse.Presence), _ -> None
              in
              (* Read after registering, which the live handoff below needs,
                 and before responding: an observer's response headers say
                 whether the replay starts after a gap. An agent-stream client
                 reads no such header, so its gap is not reported. *)
              let replay =
                Option.map
                  (Sse.replay_after_for_session
                     ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
                     ?observer_instance_id ~client_id ~session_id ~kind:sse_kind)
                  last_event_id
              in
              let observer_headers =
                match observer_handshake with
                | None -> []
                | Some handshake ->
                    let missed_through =
                      match replay with
                      | Some { Sse.continuity = Sse.After_gap { missed_through }; _ } ->
                          Some missed_through
                      | Some { Sse.continuity = Sse.Continuous; _ } | None -> None
                    in
                    Sse_wire.observer_response_headers
                      (Sse_wire.observer_after_replay handshake ~missed_through)
                    @ [ Server_mcp_transport_http_headers.observer_idle_timeout_header,
                        string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms ]
              in
              (* This receipt is emitted only after the exact requested scope
                 matched, the scope was still current, and readiness was
                 rechecked. Build fields are embedded process facts. *)
              let identity_headers =
                match attested_runtime with
                | None | Some (Error _) -> []
                | Some (Ok runtime) ->
                    (match sse_kind, observer_handshake, admission_headers, observer_scope with
                     | Sse.Observer, Some _, [receipt], Some (_, scope)
                       when receipt = Workspace.read_precondition_admission_header
                            && String.equal runtime.base_path scope.config.base_path ->
                         Sse_wire.observer_identity_headers
                           { version = Runtime_build_version.current
                           ; binary_commit = Build_identity.embedded_commit }
                     | (Sse.Observer | Sse.Agent_stream | Sse.Presence), _, _, _ -> [])
              in
              let stream_headers =
                let headers = sse_stream_headers ~deps session_id protocol_version origin in
                match standalone_observer_instance with
                | None -> headers
                | Some _ ->
                  (* This id belongs only to the live SSE connection, not an MCP
                     session. Returning it as a cookie or session header would
                     cause a subsequent Observer request to fail session lookup. *)
                  List.filter (fun (name, value) ->
                    match String.lowercase_ascii name with
                    | "mcp-session-id" -> false
                    | "set-cookie" when String.starts_with ~prefix:"mcp-session-id=" value -> false
                    | _ -> true) headers
              in
              let headers =
                Httpun.Headers.of_list
                  (admission_headers @ observer_headers @ identity_headers @ stream_headers)
              in
              let response = Httpun.Response.create ~headers `OK in
              if not (scope_is_current ()) then begin
                Sse.unregister_if_current session_id client_id;
                refuse_workspace Workspace.Workspace_precondition_failed
              end else if sse_kind = Sse.Observer && not (deps.is_ready ()) then begin
                Sse.unregister_if_current session_id client_id;
                respond_not_ready ~deps request reqd
              end else (
          (match evicted with
          | Some evicted_sid ->
              (* RFC-0099 PR-3: cap-exceeded eviction publishes the typed
                 Evict/Close event pair. *)
              stop_sse_session_evict evicted_sid
                ~reason:Session_lifecycle_event.Cap_exceeded
          | None -> ());
          match (match attested_runtime with
             | Some result -> result
             | None -> deps.get_runtime_result ()) with
          | Error msg ->
              (* No supervisor could own the response, so the stream ends at
                 once with the status it always had (RFC-0493 §3.2). *)
              Log.Server.debug "SSE runtime unavailable for session %s: %s"
                session_id msg;
              Sse.unregister_if_current session_id client_id;
              Http_reqd.respond_with_string reqd response ""
          | Ok runtime ->
          let response =
            Server_sse_response.respond ~clock:runtime.clock
              ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s reqd response
          in
          let info = make_sse_conn ~session_id ~client_id ~response () in
          let published = register_sse_conn_if_newer ~session_id ~info in
          Atomic.set owned_info (Some info);
          (match published with
           | false ->
             Eio.Cancel.protect (fun () ->
               Fun.protect ~finally:disconnect_play (fun () ->
                 stop_sse_conn_if_current info));
             Eio.Fiber.check ()
           | true ->
          if Atomic.get disconnected then stop_sse_conn_if_current info;
          let send_if_current data : Server_sse_response.outcome =
            if scope_is_current () then send_raw info data
            else (stop_sse_conn_if_current info; Closed)
          in
          let replayed =
            match replay with
            | Some { Sse.deliveries; continuity = _ } -> deliveries
            | None -> []
          in
              let sw = runtime.sw in
              let clock = runtime.clock in
              Option.iter (fun machine ->
                Option.iter (fun (_, (scope : Mcp_server.workspace_scope)) ->
                  Server_machine_spectator.start ~sw ~clock ~stop_promise:info.stop_promise
                    ~machine ~config:scope.config) observer_scope) machine;
              Option.iter (fun browser ->
                Option.iter (fun (_, (scope : Mcp_server.workspace_scope)) ->
                  Server_browser_spectator.start ~sw ~clock ~stop_promise:info.stop_promise
                    ~scope:browser ~config:scope.config) observer_scope) browser;
              Option.iter (fun (_, scope) ->
                Eio.Fiber.fork_daemon ~sw (fun () ->
                  (match Eio.Fiber.first
                    (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope); `Replaced)
                    (fun () -> Eio.Promise.await info.stop_promise; `Stopped) with
                   | `Replaced -> stop_sse_conn_if_current info
                   | `Stopped -> ());
                  `Stop_daemon)) observer_scope;
              (* The drain sends the prime and the replay too, under the
                 supervisor, so a stop cancels one that waits for the socket
                 (RFC-0493 §3.2). *)
              run_sse_pumps ~sw info
                ~drain:(fun () ->
                  match
                    drain_sse info ~clock ~prime:(sse_prime_event ()) ~replay:replayed
                      ~frame_of:(fun delivery -> delivery.Sse.frame)
                      ~send:send_if_current event_stream
                  with
                  | Client_gone | Stalled ->
                    Log.Server.debug "SSE drain send failed for session %s" info.session_id
                  | Source_stopped | Finished -> ()
                  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
                  | exception exn ->
                    Log.Server.error "drain loop error: %s" (Printexc.to_string exn))
                ~ping:(fun () ->
                  let is_cancelled exn =
                    match exn with
                    | Eio.Cancel.Cancelled _ -> true
                    | _ -> false
                  in
                  let rec loop () =
                    if not (Atomic.get info.stop) then (
                      (try Eio.Time.sleep clock (ping_interval ())
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping sleep error: %s"
                           (Printexc.to_string exn));
                      (try
                         if Atomic.get info.closed then
                           stop_sse_conn_if_current info
                         else if not (Atomic.get info.stop) then begin
                           renew_play ();
                           match send_if_current ": ping\n\n" with
                           | Written -> ()
                           | Closed | Stalled ->
                             Log.Server.debug "SSE ping send failed for session %s"
                               info.session_id
                         end
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping send error: %s"
                           (Printexc.to_string exn);
                         stop_sse_conn_if_current info);
                      loop ())
                  in
                   try loop () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                     if is_cancelled exn then ()
                     else
                       Log.Server.error "ping loop error: %s"
                         (Printexc.to_string exn));
          let client_count = Sse.client_count () in
          if client_count > Sse.max_clients / 2 then
              Log.Server.info "SSE connected: %s (active: %d/%d)"
              session_id client_count Sse.max_clients)))))))))


let handle_get_operator_mcp ~deps request reqd =
  let request_authority = Server_request_authority.current_exn () in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path = deps.get_base_path () in
  match deps.verify_operator_mcp_auth ~base_path request with
  | Error failure ->
      respond_mcp_auth_error
        ~deps
        ~request_authority
        ~endpoint:(get_endpoint_label Operator_remote)
        request
        reqd
        ~session_id
        ~protocol_version
        failure
  | Ok () ->
      handle_get_mcp ~deps ~profile:Operator_remote request reqd

let handle_delete_mcp ~deps ?(profile = Full) request reqd =
  let request_authority = Server_request_authority.current_exn () in
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let base_path = deps.get_base_path () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        deps.verify_mcp_auth ~base_path request
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
    | Seat ->
        deps.verify_seat_mcp_auth ~base_path request
  in
  match auth_result with
  | Error failure ->
      let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
      let protocol_version = get_protocol_version_for_session ~session_id request in
      respond_mcp_auth_error
        ~deps
        ~request_authority
        ~endpoint:(delete_endpoint_label profile)
        request
        reqd
        ~session_id
        ~protocol_version
        failure
  | Ok () -> (
      match get_session_id_any request with
      | Some session_id -> (
          match validate_mcp_session_delete_profile ~profile session_id with
          | Error msg ->
              let headers =
                Httpun.Headers.of_list
                  [ ("content-length", string_of_int (String.length msg)) ]
              in
              let response = Httpun.Response.create ~headers `Conflict in
              Http_reqd.respond_with_string reqd response msg
          | Ok () -> (
              match validate_protocol_version_continuity ~session_id request with
              | Error rejection ->
                  let body = protocol_version_rejection_body rejection in
                  let protocol_version =
                    get_protocol_version_for_session ~session_id request
                  in
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", string_of_int (String.length body))
                      :: json_headers ~deps session_id protocol_version
                           (deps.get_origin request))
                  in
                  let response =
                    Httpun.Response.create ~headers `Bad_request
                  in
                  Http_reqd.respond_with_string reqd response body
              | Ok () ->
               let protocol_version = get_protocol_version request in
               let sse_active_before_stop = is_active_sse_session session_id in
               stop_sse_session session_id;
               Sse.unregister session_id;
               let resource_cleanup =
                 match deps.get_runtime_result () with
                 | Ok runtime ->
                     runtime.clear_resource_subscriptions_for_session session_id;
                     "cleared"
                 | Error msg ->
                     Log.Server.debug
                       "skip resource subscription cleanup for session %s: %s"
                       session_id msg;
                     "skipped_runtime_unavailable"
               in
               forget_mcp_session session_id;
               Log.Mcp_transport.info "Session terminated: %s reason=client_delete profile=%s \
                  protocol_version=%s sse_active_before_stop=%b \
                  resource_cleanup=%s"
                 session_id (profile_label profile) protocol_version
                 sse_active_before_stop resource_cleanup;
              let headers =
                Httpun.Headers.of_list
                  (("content-length", "0") :: mcp_headers session_id protocol_version)
              in
              let response = Httpun.Response.create ~headers `No_content in
              Http_reqd.respond_with_string reqd response ""))
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers =
            Httpun.Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Http_reqd.respond_with_string reqd response body)

module For_testing = struct
  let with_ping_interval seconds fn =
    let previous = Atomic.get ping_interval_override in
    Atomic.set ping_interval_override (Some seconds);
    Fun.protect ~finally:(fun () -> Atomic.set ping_interval_override previous) fn

  let with_disconnect_hook replacement fn =
    let previous = !disconnect_test_hook in
    disconnect_test_hook := replacement;
    Fun.protect ~finally:(fun () -> disconnect_test_hook := previous) fn
end
