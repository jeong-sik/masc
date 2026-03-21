module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Http_negotiation = Mcp_protocol.Http_negotiation

type deps = Server_mcp_transport_http_types.deps

let handle_post_mcp ~(deps : deps) ?(profile = Mcp_eio.Full) request reqd =
  let session_id =
    match Server_mcp_transport_http_session.get_session_id_any request with
    | Some sid -> sid
    | None -> Mcp_session.generate ()
  in
  let auth_token = deps.auth_token_from_request request in
  let protocol_version =
    Server_mcp_transport_http_session.get_protocol_version_for_session
      ~session_id request
  in
  let origin = deps.get_origin request in
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> Server_mcp_transport_http_session.default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ ->
        deps.verify_mcp_auth ~base_path request
    | Mcp_eio.Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  match
    Server_mcp_transport_http_session.validate_mcp_session_profile ~profile
      session_id
  with
  | Error msg ->
      let body =
        Printf.sprintf
          {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
          (Yojson.Safe.to_string (`String msg))
      in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: Server_mcp_transport_http_headers.json_headers ~deps session_id
               protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response body
  | Ok () -> (
      match
        Server_mcp_transport_http_session.validate_protocol_version_continuity
          ~session_id request
      with
      | Error msg ->
          let body =
            Printf.sprintf
              {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
              (Yojson.Safe.to_string (`String msg))
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: Server_mcp_transport_http_headers.json_headers ~deps session_id
                   protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Ok () ->
          Server_mcp_transport_http_session.remember_mcp_profile session_id
            profile;
          (match auth_result with
          | Error msg ->
              Server_mcp_transport_http_headers.respond_mcp_auth_error ~deps
                request reqd ~session_id ~protocol_version msg
          | Ok () ->
              Http.Request.read_body_async reqd (fun body_str ->
                  let accept_mode =
                    Server_mcp_transport_http_headers.classify_mcp_accept_for_body
                      request body_str
                  in
                  match accept_mode with
                  | Http_negotiation.Rejected ->
                      let body =
                        Yojson.Safe.to_string
                          (`Assoc
                            [
                              ("jsonrpc", `String "2.0");
                              ( "error",
                                `Assoc
                                  [
                                    ("code", `Int (-32600));
                                    ( "message",
                                      `String
                                        "Invalid Accept header: must include application/json and text/event-stream. Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility." );
                                  ] );
                            ])
                      in
                      let headers =
                        Httpun.Headers.of_list
                          (("content-length", string_of_int (String.length body))
                          :: Server_mcp_transport_http_headers.json_headers
                               ~deps session_id protocol_version origin)
                      in
                      let response = Httpun.Response.create ~headers `Bad_request in
                      Httpun.Reqd.respond_with_string reqd response body
                  | accept_mode ->
                      let accept_warn_headers =
                        Server_mcp_transport_http_headers.legacy_accept_warning_headers
                          accept_mode
                      in
                      match
                        Server_mcp_transport_http_headers.request_runtime_result
                          deps
                      with
                      | Error msg ->
                          Server_mcp_transport_http_headers
                          .respond_mcp_internal_error ~deps request reqd
                            ~session_id ~protocol_version msg
                      | Ok (state, sw, clock) ->
                          Eio.Fiber.fork ~sw (fun () ->
                          try
                            let response_json =
                              Mcp_eio.handle_request ~clock ~sw ~profile
                                ~mcp_session_id:session_id ?auth_token state
                                body_str
                            in
                            (match
                               Server_mcp_transport_http_session
                               .protocol_version_from_body body_str
                             with
                            | Some v ->
                                Server_mcp_transport_http_session
                                .remember_protocol_version session_id v
                            | None -> ());
                            let protocol_version =
                              Server_mcp_transport_http_session
                              .get_protocol_version_for_session ~session_id
                                request
                            in
                            let wants_sse =
                              Server_mcp_transport_http_headers
                              .should_use_sse_for_body request body_str
                                accept_mode
                              && not
                                   Server_mcp_transport_http_headers
                                   .force_json_response
                              && not
                                   (Server_mcp_transport_http_headers
                                    .request_force_json_response request)
                            in
                            let respond_json status body headers =
                              let headers =
                                Httpun.Headers.of_list
                                  (("content-length", string_of_int (String.length body))
                                  :: headers)
                              in
                              Httpun.Reqd.respond_with_string reqd
                                (Httpun.Response.create ~headers status)
                                body
                            in
                            if wants_sse then
                              match response_json with
                              | `Null ->
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .mcp_headers session_id protocol_version
                                  in
                                  respond_json `Accepted "" headers
                              | json
                                when Server_mcp_transport_http_headers
                                     .is_http_error_response json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .json_headers ~deps session_id
                                      protocol_version origin
                                  in
                                  respond_json `Bad_request body headers
                              | json ->
                                  let event =
                                    Sse.format_event ~event_type:"message"
                                      (Yojson.Safe.to_string json)
                                  in
                                  let body =
                                    Server_mcp_transport_http_headers
                                    .sse_prime_event ()
                                    ^ event
                                  in
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .sse_headers ~deps session_id
                                      protocol_version origin
                                  in
                                  respond_json `OK body headers
                            else
                              match response_json with
                              | `Null ->
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .mcp_headers session_id protocol_version
                                  in
                                  respond_json `Accepted "" headers
                              | json
                                when Server_mcp_transport_http_headers
                                     .is_http_error_response json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .json_headers ~deps session_id
                                      protocol_version origin
                                  in
                                  respond_json `Bad_request body headers
                              | json ->
                                  let body = Yojson.Safe.to_string json in
                                  let headers =
                                    accept_warn_headers
                                    @ Server_mcp_transport_http_headers
                                      .json_headers ~deps session_id
                                      protocol_version origin
                                  in
                                  respond_json `OK body headers
                      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                        let protocol_version =
                          Server_mcp_transport_http_session
                          .get_protocol_version_for_session ~session_id request
                        in
                        Server_mcp_transport_http_headers.respond_mcp_internal_error
                          ~deps request reqd ~session_id ~protocol_version
                          ("Internal error: " ^ Printexc.to_string exn)))))

let handle_get_mcp ~(deps : deps) ?legacy_messages_endpoint
    ?(profile = Mcp_eio.Full)
    request reqd =
  let origin = deps.get_origin request in
  let session_id =
    Mcp_session.get_or_generate
      (Server_mcp_transport_http_session.get_session_id_any request)
  in
  let protocol_version =
    Server_mcp_transport_http_session.get_protocol_version_for_session
      ~session_id request
  in
  let legacy_headers =
    match legacy_messages_endpoint with
    | Some _ ->
        Server_mcp_transport_http_headers.legacy_transport_deprecation_headers
    | None -> []
  in
  let last_event_id =
    Server_mcp_transport_http_headers.get_last_event_id request
  in
  match
    Server_mcp_transport_http_session.validate_mcp_session_profile ~profile
      session_id
  with
  | Error msg ->
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length msg))
          :: Server_mcp_transport_http_headers.json_headers ~deps session_id
               protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response msg
  | Ok () -> (
      match
        Server_mcp_transport_http_session.validate_protocol_version_continuity
          ~session_id request
      with
      | Error msg ->
          let body =
            Printf.sprintf
              {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
              (Yojson.Safe.to_string (`String msg))
          in
          let headers =
            Httpun.Headers.of_list
              (("content-length", string_of_int (String.length body))
              :: Server_mcp_transport_http_headers.json_headers ~deps session_id
                   protocol_version origin)
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Ok () ->
          Server_mcp_transport_http_session.remember_mcp_profile session_id
            profile;
          (match
             Server_mcp_transport_http_sse.check_sse_connect_guard session_id
           with
          | Error (reason, retry_after_s) ->
              Server_mcp_transport_http_sse.respond_sse_rate_limited ~deps
                ~origin ~session_id ~protocol_version ~reason ~retry_after_s
                reqd
          | Ok () ->
              Server_mcp_transport_http_sse.stop_sse_session session_id;
              let headers =
                Httpun.Headers.of_list
                  (legacy_headers
                  @ Server_mcp_transport_http_headers.sse_stream_headers ~deps
                      session_id protocol_version origin)
              in
              let response = Httpun.Response.create ~headers `OK in
              let writer = Httpun.Reqd.respond_with_streaming reqd response in
              let mutex = Eio.Mutex.create () in
              let info_ref :
                  Server_mcp_transport_http_sse.sse_conn_info option ref =
                ref None
              in
              let push event =
                match !info_ref with
                | None -> ()
                | Some info ->
                    ignore
                      (Server_mcp_transport_http_sse.send_raw info event)
              in
              let client_id, evicted =
                Sse.register session_id ~push
                  ~last_event_id:(Option.value ~default:0 last_event_id)
              in
              (match evicted with
              | Some evicted_sid ->
                  Server_mcp_transport_http_sse.stop_sse_session evicted_sid
              | None -> ());
              let info =
                {
                  Server_mcp_transport_http_sse.session_id;
                  client_id;
                  writer;
                  mutex;
                  stop = ref false;
                  closed = false;
                }
              in
              info_ref := Some info;
              Hashtbl.replace
                Server_mcp_transport_http_sse.sse_conn_by_session session_id
                info;
              ignore
                (Server_mcp_transport_http_sse.send_raw info
                   (Server_mcp_transport_http_headers.sse_prime_event ()));
              (match legacy_messages_endpoint with
              | None -> ()
              | Some f ->
                  let endpoint_url = f session_id in
                  ignore
                    (Server_mcp_transport_http_sse.send_raw info
                       (Sse.format_event ~event_type:"endpoint" endpoint_url)));
              (match last_event_id with
              | Some last_id ->
                  let missed = Sse.get_events_after last_id in
                  List.iter
                    (fun ev ->
                      ignore
                        (Server_mcp_transport_http_sse.send_raw info ev))
                    missed
              | None -> ());
              (match (deps.get_sw (), deps.get_clock ()) with
              | Some sw, Some clock ->
                  Eio.Fiber.fork ~sw (fun () ->
                      let is_cancelled exn =
                        match exn with
                        | Eio.Cancel.Cancelled _ -> true
                        | _ -> false
                      in
                      let rec loop () =
                        if not !(info.stop) then (
                          (try
                             Eio.Time.sleep clock
                               Server_mcp_transport_http_headers
                               .sse_ping_interval_s
                           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                             if is_cancelled exn then raise exn;
                             Log.Server.error "ping sleep error: %s"
                               (Printexc.to_string exn));
                          (try
                             if info.closed then
                               Server_mcp_transport_http_sse.stop_sse_session
                                 info.session_id
                             else if not !(info.stop) then
                               ignore
                                 (Server_mcp_transport_http_sse.send_raw info
                                    ": ping\n\n")
                           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                             if is_cancelled exn then raise exn;
                             Log.Server.error "ping send error: %s"
                               (Printexc.to_string exn);
                             Server_mcp_transport_http_sse.stop_sse_session
                               info.session_id);
                          loop ())
                      in
                      try loop () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                        if is_cancelled exn then ()
                        else
                          Log.Server.error "ping loop error: %s"
                            (Printexc.to_string exn))
              | _ -> ());
              let client_count = Sse.client_count () in
              if client_count > Sse.max_clients / 2 then
                Log.Server.info "📡 SSE connected: %s (active: %d/%d)"
                  session_id client_count Sse.max_clients))
