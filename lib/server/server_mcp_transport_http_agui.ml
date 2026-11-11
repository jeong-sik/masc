(** Server_mcp_transport_http_agui — AG-UI SSE bridge handler. *)

open Server_mcp_transport_http_protocol
open Server_mcp_transport_http_conn
open Server_mcp_transport_http_respond

let sse_stream_headers = Server_mcp_transport_http_headers.sse_stream_headers

let ag_ui_event_of_masc_event (delivery : Sse.delivery) =
  Ag_ui.of_custom
    ~timestamp:delivery.emitted_at
    ~name:"MASC_EVENT"
    delivery.payload
  |> Ag_ui.event_to_sse ~id:delivery.event_id

let sse_ping_interval_s = 30.0

let presence_stream_headers ~deps raw_session_id protocol_version origin =
  Httpun.Headers.of_list
    ([
       ("content-type", Http_negotiation.sse_content_type);
       ("cache-control", "no-cache");
       (* This streaming body is close-delimited by Httpun. *)
       ("connection", "close");
       ("x-accel-buffering", "no");
       Server_mcp_transport_http_headers.session_cookie_header raw_session_id;
     ]
    @ Server_mcp_transport_http_headers.mcp_headers raw_session_id
        protocol_version
    @ deps.cors_headers origin)

let presence_session_id raw_session_id = "presence:" ^ raw_session_id

let handle_ag_ui_events ~deps request reqd =
  let request_authority = Server_request_authority.current_exn () in
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path = deps.get_base_path () in
  (* workspace query param ignored — namespace retired *)
  let last_event_id = Server_mcp_transport_http_headers.get_last_event_id request in
  match deps.verify_mcp_observer_stream_auth ~base_path request with
  | Error failure ->
      respond_mcp_auth_error
        ~deps
        ~request_authority
        ~endpoint:"GET /ag-ui/events"
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
            (Server_mcp_transport_http_headers.last_event_id_error_to_string error)
      | Ok last_event_id ->
          let token = Server_auth.observer_sse_auth_token_from_request request in
          let auth = { Sse.config = base_path; token } in
          (match check_sse_connect_guard session_id with
          | Error (reason, retry_after_s) ->
              respond_sse_rate_limited ~deps ~origin ~session_id:(Some session_id) ~protocol_version
                ~reason ~retry_after_s reqd
          | Ok () ->
              stop_sse_session_preserve_guard session_id;
              if Option.is_some last_event_id then
                Transport_metrics.inc_sse_reconnect ();
              ensure_sse_backing_session_for_known_transport_session
                ~transport_session_id:session_id ~sse_session_id:session_id;
              let expected_resource = Server_oauth_metadata.resource request_authority in
              (match
                 Auth_oauth.with_expected_resource expected_resource (fun () ->
                   Sse.register ~kind:Sse.Observer ~auth session_id
                     (* DET-OK: unchanged from main; the authority wrapper only re-indented it. *)
                     ~last_event_id:(Option.value ~default:0 last_event_id)
                     ~on_disconnect:(fun () -> stop_sse_session session_id))
               with
               | Error reg_err ->
                   let msg = Sse.registration_error_to_string reg_err in
                   Log.Server.warn "%s" msg;
                   respond_sse_register_error ~deps ~origin ~protocol_version reqd msg
               | Ok (client_id, event_stream, evicted) ->
                  let headers =
                    Httpun.Headers.of_list
                      (sse_stream_headers ~deps session_id protocol_version origin)
                  in
                  let response = Httpun.Response.create ~headers `OK in
                  (match evicted with
                  | Some evicted_sid ->
                      (* RFC-0099 PR-3: cap-exceeded eviction publishes the
                         typed Evict/Close event pair. *)
                      stop_sse_session_evict evicted_sid
                        ~reason:Session_lifecycle_event.Cap_exceeded
                  | None -> ());
                  (match deps.get_runtime_result () with
                  | Error msg ->
                      (* No supervisor could own the response, so the stream
                         ends at once (RFC-0493 §3.2). *)
                      Log.Server.debug "ag-ui SSE runtime unavailable for session %s: %s"
                        session_id msg;
                      Sse.unregister_if_current session_id client_id;
                      Http_reqd.respond_with_string reqd response ""
                  | Ok runtime ->
                  let response =
                    Server_sse_response.respond ~clock:runtime.clock
                      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
                      reqd response
                  in
                  let info = make_sse_conn ~session_id ~client_id ~response () in
                  register_sse_conn ~session_id ~info;
                  let prime =
                    Ag_ui.(
                      make_event ~thread_id:default_thread_id ~run_id:(Some session_id) Run_started
                      |> event_to_sse)
                  in
                      let sw = runtime.sw in
                      let clock = runtime.clock in
                      (* The drain sends the prime and the replay too, under
                         the supervisor, so a stop cancels one that waits for
                         the socket (RFC-0493 §3.2). *)
                      run_sse_pumps ~sw info
                        ~drain:(fun () ->
                          match
                            let replay =
                              match last_event_id with
                              | Some last_id ->
                                (* No AG-UI client reads a replay gap yet, so
                                   only the deliveries are sent. *)
                                (Sse.replay_after_for_session
                                   ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
                                   ~client_id ~session_id ~kind:Sse.Observer last_id).Sse.deliveries
                              | None -> []
                            in
                            drain_sse info ~clock ~prime ~replay
                              ~frame_of:ag_ui_event_of_masc_event ~send:(send_raw info)
                              event_stream
                          with
                          | Client_gone | Stalled ->
                            Log.Server.debug "ag-ui drain send failed for session %s"
                              info.session_id
                          | Source_stopped | Finished -> ()
                          | exception (Eio.Cancel.Cancelled _ as e) -> raise e
                          | exception exn ->
                            Log.Server.error "ag-ui drain loop error: %s"
                              (Printexc.to_string exn))
                        ~ping:(fun () ->
                          let rec loop () =
                            if not (Atomic.get info.stop) then (
                              (try Eio.Time.sleep clock sse_ping_interval_s
                               with Eio.Cancel.Cancelled _ as exn -> raise exn
                                  | exn -> Log.Server.debug "SSE ping sleep interrupted: %s" (Printexc.to_string exn));
                              (try
                                 if Atomic.get info.closed then
                                   stop_sse_session_preserve_guard info.session_id
                                 else if not (Atomic.get info.stop) then
                                   (match send_raw info ": ping\n\n" with
                                    | Written -> ()
                                    | Closed | Stalled ->
                                      Log.Server.debug "ag-ui ping send failed for session %s"
                                        info.session_id)
                               with Eio.Cancel.Cancelled _ as exn -> raise exn
                                  | exn ->
                                      Log.Server.warn "SSE ping send failed for session %s: %s" info.session_id (Printexc.to_string exn);
                                      stop_sse_session_preserve_guard info.session_id);
                              loop ())
                          in
                          try loop () with Eio.Cancel.Cancelled _ as exn -> raise exn
                            | exn ->
                                Log.Server.error "SSE ping loop exited for session %s: %s" info.session_id (Printexc.to_string exn);
                                stop_sse_session_preserve_guard info.session_id)))))

let handle_presence_events ~deps request reqd =
  let request_authority = Server_request_authority.current_exn () in
  let origin = deps.get_origin request in
  let raw_session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let session_id = presence_session_id raw_session_id in
  let protocol_version =
    get_protocol_version_for_session ~session_id:raw_session_id request
  in
  let base_path = deps.get_base_path () in
  match deps.verify_mcp_observer_stream_auth ~base_path request with
  | Error failure ->
      respond_mcp_auth_error
        ~deps
        ~request_authority
        ~endpoint:"GET /events/presence"
        request
        reqd
        ~session_id:raw_session_id
        ~protocol_version
        failure
  | Ok () ->
      let token = Server_auth.observer_sse_auth_token_from_request request in
      let auth = { Sse.config = base_path; token } in
      (match check_sse_connect_guard session_id with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~session_id:(Some session_id)
            ~protocol_version ~reason ~retry_after_s reqd
      | Ok () ->
          stop_sse_session_preserve_guard session_id;
          ensure_sse_backing_session_for_known_transport_session
            ~transport_session_id:raw_session_id ~sse_session_id:session_id;
          let expected_resource = Server_oauth_metadata.resource request_authority in
          (match
             Auth_oauth.with_expected_resource expected_resource (fun () ->
               Sse.register ~kind:Sse.Presence ~auth session_id ~last_event_id:0
                 ~on_disconnect:(fun () ->
                   stop_sse_session_preserve_guard session_id))
           with
           | Error reg_err ->
               let msg = Sse.registration_error_to_string reg_err in
               Log.Server.warn "%s" msg;
               respond_sse_register_error ~deps ~origin ~protocol_version reqd msg
           | Ok (client_id, event_stream, evicted) ->
              let headers =
                presence_stream_headers ~deps raw_session_id protocol_version origin
              in
              let response = Httpun.Response.create ~headers `OK in
          (match evicted with
          | Some evicted_sid ->
              (* RFC-0099 PR-3: cap-exceeded eviction publishes the typed
                 Evict/Close event pair. *)
              stop_sse_session_evict evicted_sid
                ~reason:Session_lifecycle_event.Cap_exceeded
          | None -> ());
          match deps.get_runtime_result () with
          | Error msg ->
              (* No supervisor could own the response, so the stream ends at
                 once (RFC-0493 §3.2). *)
              Log.Server.debug
                "presence SSE runtime unavailable for session %s: %s"
                session_id msg;
              Sse.unregister_if_current session_id client_id;
              Http_reqd.respond_with_string reqd response ""
          | Ok runtime ->
          let response =
            Server_sse_response.respond ~clock:runtime.clock
              ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
              reqd response
          in
          let info = make_sse_conn ~session_id ~client_id ~response () in
          register_sse_conn ~session_id ~info;
              let sw = runtime.sw in
              let clock = runtime.clock in
              (* The drain sends the prime too, under the supervisor, so a
                 stop cancels it while it waits for the socket (RFC-0493
                 §3.2). *)
              run_sse_pumps ~sw info
                ~drain:(fun () ->
                  match
                    drain_sse info ~clock
                      ~prime:
                        (Server_mcp_transport_http_headers.sse_comment_with_retry
                           ~comment:"presence-stream")
                      ~replay:[] ~frame_of:(fun delivery -> delivery.Sse.frame)
                      ~send:(send_raw info) event_stream
                  with
                  | Client_gone | Stalled ->
                    Log.Server.debug "presence drain send failed for session %s"
                      info.session_id
                  | Source_stopped | Finished -> ()
                  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
                  | exception exn ->
                    Log.Server.error "presence drain loop error: %s"
                      (Printexc.to_string exn))
                ~ping:(fun () ->
                  let rec loop () =
                    if not (Atomic.get info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                           Log.Server.debug
                             "presence ping sleep interrupted: %s"
                             (Printexc.to_string exn));
                      (try
                         if Atomic.get info.closed then
                           stop_sse_session_preserve_guard info.session_id
                         else if not (Atomic.get info.stop) then
                           (match send_raw info ": ping\n\n" with
                            | Written -> ()
                            | Closed | Stalled ->
                              Log.Server.debug
                                "presence ping send failed for session %s"
                                info.session_id)
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                           Log.Server.warn
                             "presence ping send failed for session %s: %s"
                             info.session_id (Printexc.to_string exn);
                           stop_sse_session_preserve_guard info.session_id);
                      loop ())
                  in
                  try loop ()
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error
                        "presence ping loop exited for session %s: %s"
                        info.session_id (Printexc.to_string exn))))
