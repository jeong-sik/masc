(** Server_mcp_transport_http — SSE/POST MCP transport handler. *)

type tool_profile = Server_mcp_transport_http_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type runtime = Server_mcp_transport_http_types.runtime = {
  base_path : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  handle_request :
    ?profile:tool_profile ->
    ?mcp_session_id:string ->
    ?otel_mcp_protocol_version:string ->
    ?otel_transport_context:Otel_dispatch_hook.transport_context ->
    ?auth_token:string ->
    ?internal_keeper_runtime:bool ->
    string ->
    Yojson.Safe.t;
}

include Server_mcp_transport_http_protocol
include Server_mcp_transport_http_conn
include Server_mcp_transport_http_respond
include Server_mcp_transport_http_agui

(** [safe_respond_with_string] is a local guard against the
    [Failure "invalid state, currently handling error"] race that
    httpun raises when a client disconnects during a long OAS turn
    (2026-05-05 cycle9 FATAL incident).  All direct
    [Httpun.Reqd.respond_with_string] calls in this file use this
    wrapper instead of the raw httpun call. *)
let safe_respond_with_string reqd response body =
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http-post] respond_with_string skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http-post] respond_with_string unexpected exception: %s"
        (Printexc.to_string exn)

(* RFC-0100 PR-2: chunked first-flush variant of safe_respond_with_string.
   Writes [body] via [Httpun.Reqd.respond_with_streaming] so the response
   uses [Transfer-Encoding: chunked] framing instead of
   [Content-Length: N]. Body bytes and headers (other than transfer-encoding /
   content-length) are byte-identical to the non-chunked form, so well-behaved
   JSON clients are unaffected.

   The 50 ms first-flush budget is implicit at PR-2 — current sync code
   paths compute the body in well under 50 ms, so the first (and only)
   chunk flushes immediately. The placeholder-stub flow for slow paths
   is RFC-0100 PR-3's auto-upgrade work, not this PR.

   Same race-safe wrapping as {!safe_respond_with_string} — the
   2026-05-05 OAS cancel-race exception class is caught and downgraded
   to a WARN. *)
let safe_respond_chunked reqd response body =
  try
    let writer = Httpun.Reqd.respond_with_streaming reqd response in
    Httpun.Body.Writer.write_string writer body ;
    Httpun.Body.Writer.close writer
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn
        "[mcp-http-post] respond_chunked unexpected exception: %s"
        (Printexc.to_string exn)

let body_jsonrpc_method = Server_mcp_transport_http_headers.body_jsonrpc_method

let sse_prime_event = Server_mcp_transport_http_headers.sse_prime_event

let sse_ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

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
      @ mcp_headers protocol_version
      @ deps.cors_headers origin)

let stream_post_sse_start ~deps ~origin ~session_id ~protocol_version
    reqd =
  let headers =
    stream_post_sse_headers ~deps ~origin ~session_id ~protocol_version
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  make_inline_sse_conn ~session_id writer

let spawn_post_sse_keepalive ~sw ~clock info =
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        if not (Atomic.get info.stop) then (
          (try
             Eio.Time.sleep clock post_sse_keepalive_interval_s
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Log.Server.warn "SSE keepalive sleep failed for session %s: %s"
                    info.session_id (Printexc.to_string exn));
          if Atomic.get info.closed then
            close_sse_conn info
          else if not (Atomic.get info.stop) then
            if not (send_raw info ": keepalive\n\n") then
              Log.Server.debug "SSE keepalive send failed for session %s"
                info.session_id;
          loop ())
      in
      try loop ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> close_sse_conn info)

let stream_post_sse_finish info = close_sse_conn info

let stream_post_sse_json info (json : Yojson.Safe.t) =
  if not (send_raw info
            (Sse.format_event ~event_type:"message" (Yojson.Safe.to_string json)))
  then
    Log.Server.debug "SSE json send failed for session %s" info.session_id

let should_stream_post_tools_call request body_str accept_mode =
  should_use_sse_for_body request accept_mode
  && not force_json_response
  && not (request_force_json_response request)
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

let inject_agent_name_into_body ?(rewrite_existing = false) ?(strip_token = false)
    ~agent_name body_str =
  Server_mcp_actor_injection.inject_agent_name_into_body ~rewrite_existing
    ~strip_token ~agent_name body_str

let body_with_canonical_http_actor ~base_path ~auth_token request body_str =
  let actor = Server_auth.dashboard_actor_for_request ~base_path request in
  Server_mcp_actor_injection.reduce ~actor ~auth_token body_str

let handle_post_mcp ~deps ?(profile = Full) request reqd =
  let request_authority = Server_request_authority.current_exn () in
  (* Readiness gate: reject before session/auth if server state is not ready *)
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  match
    Server_mcp_transport_http_headers.request_protocol_version_header request
  with
  | None ->
      let body =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Null)
          ; ( "error"
            , `Assoc
                [ ("code", `Int (-32020))
                ; ("message", `String "missing MCP-Protocol-Version header")
                ] )
          ]
        |> Yojson.Safe.to_string
      in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
           :: json_headers ~deps Mcp_transport_protocol.default_protocol_version
                (deps.get_origin request))
      in
      safe_respond_with_string reqd
        (Httpun.Response.create ~headers `Bad_request) body
  | Some requested
    when not
           (Mcp_transport_protocol.is_supported_protocol_version requested) ->
      let body =
        Server_mcp_transport_http_headers.unsupported_protocol_version_error_body
          requested
      in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: json_headers ~deps Mcp_transport_protocol.default_protocol_version
               (deps.get_origin request))
      in
      safe_respond_with_string reqd
        (Httpun.Response.create ~headers `Bad_request) body
  | Some protocol_version ->
  (* The admitted authority is a fiber-local binding whose dynamic extent is the
     router dispatch (bin/main_eio.ml for HTTP/1.1, server_h2_gateway for h2c).
     Everything below runs from the async body callback and from a fiber forked
     onto runtime.sw, both outside that extent, so read it here and carry the
     value. *)
  let expected_resource =
    Server_oauth_metadata.resource request_authority
  in
  let auth_token = deps.auth_token_from_request request in
  let origin = deps.get_origin request in
  let base_path = deps.get_base_path () in
  let auth_result =
    match profile with
    | Full | Managed_agent ->
        deps.verify_mcp_auth ~base_path request
    | Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  let open Result.Syntax in
  ignore (
    let* () =
      match auth_result with
      | Ok () -> Ok ()
      | Error failure ->
          respond_mcp_error
            ?data:(auth_failure_data failure)
            ~code:Mcp_error_code.Auth_error
            ~deps
            ~request_authority
            request
            reqd
            ~protocol_version
            failure.message;
          Error ()
    in
    Ok (Http.Request.read_body_async reqd (fun body_str ->
      ignore (
      let* post_context =
        match
          Server_mcp_request_context.decide_post_body ~request body_str
        with
        | Ok decision -> Ok decision
        | Error (Server_mcp_request_context.Invalid_accept msg) ->
            let body =
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("jsonrpc", `String "2.0");
                    ( "error",
                      `Assoc
                        [
                          ("code", `Int (Mcp_error_code.to_wire_code Invalid_request));
                          ("message", `String msg);
                        ] );
                  ])
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps protocol_version origin)
            in
            let response = Httpun.Response.create ~headers `Bad_request in
            safe_respond_with_string reqd response body;
            Error ()
        | Error (Server_mcp_request_context.Unsupported_protocol_version requested) ->
            let body =
              Yojson.Safe.to_string
                (`Assoc
                  [ ("jsonrpc", `String "2.0")
                  ; ( "id"
                    , Server_mcp_transport_http_headers.jsonrpc_id_or_null
                        body_str )
                  ; ( "error"
                    , `Assoc
                        [ ("code", `Int (-32022))
                        ; ("message", `String "Unsupported protocol version")
                        ; ( "data"
                          , `Assoc
                              [ ( "supported"
                                , `List
                                    (List.map
                                       (fun version -> `String version)
                                       Mcp_transport_protocol.supported_protocol_versions) )
                              ; ("requested", `String requested)
                              ] )
                        ] )
                  ])
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps protocol_version origin)
            in
            safe_respond_with_string reqd
              (Httpun.Response.create ~headers `Bad_request) body;
            Error ()
        | Error (Server_mcp_request_context.Header_mismatch msg) ->
            let body =
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("jsonrpc", `String "2.0");
                    ( "error",
                      `Assoc
                        [
                          ("code", `Int (-32020));
                          ("message", `String msg);
                        ] );
                    ( "id"
                    , Server_mcp_transport_http_headers.jsonrpc_id_or_null
                        body_str );
                  ])
            in
            let headers =
              Httpun.Headers.of_list
                (("content-length", string_of_int (String.length body))
                :: json_headers ~deps protocol_version origin)
            in
            let response = Httpun.Response.create ~headers `Bad_request in
            safe_respond_with_string reqd response body;
            Error ()
      in
      let accept_mode = post_context.accept_mode in
      let* runtime =
        match request_runtime_result deps with
        | Ok r -> Ok r
        | Error msg ->
            respond_mcp_error ~code:Mcp_error_code.Internal_error ~deps
              ~request_authority request reqd ~protocol_version msg;
            Error ()
      in
      let sw = runtime.sw in
      let clock = runtime.clock in
      Ok (Eio.Fiber.fork ~sw (fun () ->
                            let otel_transport_context =
                              Otel_dispatch_hook.http_transport_context
                                ~protocol_version:"1.1"
                            in
                            let response_protocol_version = protocol_version in
                            let wants_streaming_post =
                              should_stream_post_tools_call request body_str
                                accept_mode
                            in
                            let response_id = body_jsonrpc_id body_str in
                            let inline_sse : sse_conn_info option ref = ref None in
                            try
                              if wants_streaming_post then (
                                let info =
                                  stream_post_sse_start ~deps ~origin
                                    ~session_id:(Transport_correlation_id.generate ())
                                    ~protocol_version:response_protocol_version
                                    reqd
                                in
                                inline_sse := Some info;
                                spawn_post_sse_keepalive ~sw ~clock info);
                              let response_json =
                                Auth_oauth.with_expected_resource expected_resource
                                  (fun () ->
                                    let body_with_agent =
                                      body_with_canonical_http_actor ~base_path
                                        ~auth_token request body_str
                                    in
                                    let internal_keeper_runtime =
                                      Server_auth.is_verified_internal_keeper_request
                                        ~base_path request
                                    in
                                    runtime.handle_request ?auth_token ~profile
                                      ~otel_mcp_protocol_version:protocol_version
                                      ~otel_transport_context
                                      ~internal_keeper_runtime body_with_agent)
                              in
                              let wants_sse =
                                should_use_sse_for_body request accept_mode
                                && not force_json_response
                                && not (request_force_json_response request)
                              in
                              if wants_streaming_post then
                                match !inline_sse with
                                | Some info ->
                                    if response_json <> `Null then
                                      stream_post_sse_json info response_json;
                                    stream_post_sse_finish info
                                | None -> ()
                              else if wants_sse then
                                match response_json with
                                | `Null ->
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length", "0")
                                        :: mcp_headers protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    safe_respond_with_string reqd response ""
                                | json when is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: json_headers ~deps protocol_version origin)
                                    in
                                    let status : Httpun.Status.t =
                                      if Server_mcp_transport_http_headers.is_method_not_found_response json
                                      then `Not_found else `Bad_request
                                    in
                                    let response = Httpun.Response.create ~headers status in
                                    safe_respond_with_string reqd response
                                      body
                                | json ->
                                    let event =
                                      Sse.format_event ~event_type:"message"
                                        (Yojson.Safe.to_string json)
                                    in
                                    let body = event in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: sse_headers ~deps protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_with_string reqd response
                                      body
                              else
                                match response_json with
                                | `Null ->
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length", "0")
                                        :: mcp_headers protocol_version)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `Accepted
                                    in
                                    safe_respond_with_string reqd response ""
                                | json when is_http_error_response json ->
                                    let body = Yojson.Safe.to_string json in
                                    let headers =
                                      Httpun.Headers.of_list
                                        (("content-length",
                                          string_of_int (String.length body))
                                        :: json_headers ~deps protocol_version origin)
                                    in
                                    let status : Httpun.Status.t =
                                      if Server_mcp_transport_http_headers.is_method_not_found_response json
                                      then `Not_found else `Bad_request
                                    in
                                    let response = Httpun.Response.create ~headers status in
                                    safe_respond_with_string reqd response
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
                                      Httpun.Headers.of_list
                                        (("transfer-encoding", "chunked")
                                        :: json_headers ~deps protocol_version origin)
                                    in
                                    let response =
                                      Httpun.Response.create ~headers `OK
                                    in
                                    safe_respond_chunked reqd response body
                            with
                            | Eio.Cancel.Cancelled _ as e -> raise e
                            | exn ->
                                (match !inline_sse with
                                | Some info ->
                                    stream_post_sse_json info
                                      (error_body ~code:Mcp_error_code.Internal_error ?id:response_id
                                         ("Internal error: "
                                        ^ Printexc.to_string exn));
                                    stream_post_sse_finish info
                                | None ->
                                    respond_mcp_error ~code:Mcp_error_code.Internal_error
                                      ~deps ~request_authority request reqd
                                      ~protocol_version
                                      ("Internal error: "
                                     ^ Printexc.to_string exn))))))))

let handle_get_events ~deps request reqd =
  let sse_kind = Sse.Observer in
  let request_authority = Server_request_authority.current_exn () in
  if not (deps.is_ready ()) then
    respond_not_ready ~deps request reqd
  else
  let origin = deps.get_origin request in
  let protocol_version = mcp_protocol_version_default in
  let base_path = deps.get_base_path () in
  let auth_result =
    deps.verify_mcp_observer_stream_auth ~base_path request
  in
  let last_event_id = Server_mcp_transport_http_headers.get_last_event_id request in
  match auth_result with
      | Error failure ->
          respond_mcp_error
            ?data:(auth_failure_data failure)
            ~code:Mcp_error_code.Auth_error
            ~deps
            ~request_authority
            request
            reqd
            ~protocol_version
            failure.message
      | Ok () ->
          (match Transport_correlation_id.resolve (observer_session_id request) with
          | Error error ->
              respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                ~request_authority request reqd ~protocol_version
                (Transport_correlation_id.error_to_string error)
          | Ok session_id ->
          match last_event_id with
          | Error error ->
              respond_mcp_error ~code:Mcp_error_code.Invalid_request ~deps
                ~request_authority request reqd ~protocol_version
                (Server_mcp_transport_http_headers.last_event_id_error_to_string
                   error)
          | Ok last_event_id ->
      let token = Server_auth.observer_sse_auth_token_from_request request in
      let auth = { Sse.config = base_path; token } in
      (match check_sse_connect_guard session_id with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~protocol_version
            ~reason ~retry_after_s reqd
      | Ok () ->
          stop_sse_session session_id;
          if Option.is_some last_event_id then
            Transport_metrics.inc_sse_reconnect ();
          let expected_resource =
            Server_oauth_metadata.resource request_authority
          in
          (match
             Auth_oauth.with_expected_resource expected_resource (fun () ->
               Sse.register ~kind:sse_kind ~auth session_id
                 (* DET-OK: unchanged from main; the authority wrapper only re-indented it. *)
                 ~last_event_id:(Option.value ~default:0 last_event_id)
                 ~on_disconnect:(fun () -> stop_sse_session session_id))
           with
           | Error reg_err ->
               let msg = Sse.registration_error_to_string reg_err in
               Log.Server.warn "%s" msg;
               respond_observer_stream_register_error ~deps ~origin
                 ~protocol_version reqd msg
           | Ok (client_id, event_stream, evicted) ->
              let headers =
                Httpun.Headers.of_list
                  (sse_stream_headers ~deps protocol_version origin)
              in
              let response = Httpun.Response.create ~headers `OK in
              let writer = Httpun.Reqd.respond_with_streaming reqd response in
              let mutex = Eio.Mutex.create () in
              let info_ref : sse_conn_info option ref = ref None in
          (match evicted with
          | Some evicted_sid ->
              (* RFC-0099 PR-3: cap-exceeded eviction publishes typed
                 close frame + Evict/Close event pair. *)
              stop_sse_session_evict evicted_sid
                ~reason:Session_lifecycle_event.Cap_exceeded
          | None -> ());
          let info = make_sse_conn ~session_id ~client_id ~writer ~mutex () in
          info_ref := Some info;
          register_sse_conn ~session_id ~info;
          if not (send_raw info (sse_prime_event ())) then
            Log.Server.debug "SSE prime send failed for session %s" info.session_id;
          let replayed =
            match last_event_id with
            | Some last_id ->
              Sse.get_events_after_for_session ~session_id ~kind:sse_kind last_id
              |> List.filter (fun delivery ->
                if send_raw info delivery.Sse.frame
                then true
                else (
                  Log.Server.debug
                    "SSE replay send failed for session %s"
                    info.session_id;
                  false))
            | None -> []
          in
          let replay_handoff = Sse.create_replay_handoff replayed in
          (match deps.get_runtime_result () with
          | Ok runtime ->
              let sw = runtime.sw in
              let clock = runtime.clock in
              run_sse_pumps ~sw ~stop_promise:info.stop_promise
                ~drain:(fun () ->
                  let rec drain () =
                    let delivery = Eio.Stream.take event_stream in
                    (try
                      if not (Atomic.get info.closed || (Atomic.get info.stop)) then
                        if Sse.accept_live_delivery replay_handoff delivery
                           && not (send_raw info delivery.Sse.frame)
                        then
                          Log.Server.debug "SSE drain send failed for session %s"
                            info.session_id
                    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                      Log.Server.error "drain write error: %s"
                        (Printexc.to_string exn);
                      stop_sse_session info.session_id);
                    if not (Atomic.get info.stop) then drain ()
                  in
                  try drain ()
                  with Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       Log.Server.error "drain loop error: %s"
                         (Printexc.to_string exn))
                ~ping:(fun () ->
                  let is_cancelled exn =
                    match exn with
                    | Eio.Cancel.Cancelled _ -> true
                    | _ -> false
                  in
                  let rec loop () =
                    if not (Atomic.get info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping sleep error: %s"
                           (Printexc.to_string exn));
                      (try
                         if Atomic.get info.closed then
                           stop_sse_session info.session_id
                         else if not (Atomic.get info.stop) then
                           if not (send_raw info ": ping\n\n") then
                             Log.Server.debug "SSE ping send failed for session %s"
                               info.session_id
                       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                         if is_cancelled exn then raise exn;
                         Log.Server.error "ping send error: %s"
                           (Printexc.to_string exn);
                         stop_sse_session info.session_id);
                      loop ())
                  in
                   try loop () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                     if is_cancelled exn then ()
                     else
                       Log.Server.error "ping loop error: %s"
                         (Printexc.to_string exn))
          | Error msg ->
              Log.Server.debug "SSE runtime unavailable for session %s: %s"
                session_id msg);
          let client_count = Sse.client_count () in
          if client_count > Sse.max_clients / 2 then
              Log.Server.info "SSE connected: %s (active: %d/%d)"
              session_id client_count Sse.max_clients)))
