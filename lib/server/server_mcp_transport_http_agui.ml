(** Server_mcp_transport_http_agui — AG-UI SSE bridge handler. *)

open Server_mcp_transport_http_protocol
open Server_mcp_transport_http_conn
open Server_mcp_transport_http_respond

let sse_stream_headers = Server_mcp_transport_http_headers.sse_stream_headers

let ag_ui_event_of_masc_event event =
  try
    let lines = String.split_on_char '\n' event in
    let data_line =
      List.find_opt
        (fun l -> String.length l > 6 && String.starts_with ~prefix:"data: " l)
        lines
    in
    match data_line with
    | Some dl ->
        let json_str = String.sub dl 6 (String.length dl - 6) in
        let json = Yojson.Safe.from_string json_str in
        let ag_event = Ag_ui.of_custom ~name:"MASC_EVENT" json in
        Ag_ui.event_to_sse ag_event
    | None -> event
  with
  | Yojson.Json_error _ -> event
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Transport.warn "ag_ui_event_of_masc_event failed: %s" (Printexc.to_string exn);
      event

let sse_ping_interval_s = 30.0

let presence_stream_headers ~deps raw_session_id protocol_version origin =
  Httpun.Headers.of_list
    ([
       ("content-type", Http_negotiation.sse_content_type);
       ("cache-control", "no-cache");
       ("connection", "keep-alive");
       ("x-accel-buffering", "no");
       Server_mcp_transport_http_headers.session_cookie_header raw_session_id;
     ]
    @ Server_mcp_transport_http_headers.mcp_headers raw_session_id
        protocol_version
    @ deps.cors_headers origin)

let presence_session_id raw_session_id = "presence:" ^ raw_session_id

let handle_ag_ui_events ~deps request reqd =
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  (* room query param ignored — namespace retired *)
  let last_event_id =
    match Httpun.Headers.get (request : Httpun.Request.t).headers "last-event-id" with
    | Some id -> (int_of_string_opt (id))
    | None -> None
  in
  match check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
        ~reason ~retry_after_s reqd
  | Ok () ->
      stop_sse_session_preserve_guard session_id;
      if Option.is_some last_event_id then
        Transport_metrics.inc_sse_reconnect ();
      let headers =
        Httpun.Headers.of_list
          (sse_stream_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `OK in
      let writer = Httpun.Reqd.respond_with_streaming reqd response in
      let mutex = Eio.Mutex.create () in
      let info_ref : sse_conn_info option ref = ref None in
      let client_id, event_stream, evicted =
        Sse.register ~kind:Sse.Observer session_id
          ~last_event_id:(Option.value ~default:0 last_event_id)
      in
      (match evicted with
      | Some evicted_sid -> stop_sse_session evicted_sid
      | None -> ());
      let info =
        {
          session_id;
          client_id;
          writer;
          mutex;
          stop = ref false;
          closed = false;
        }
      in
      info_ref := Some info;
      register_sse_conn ~session_id ~info;
      (* See [server_mcp_transport_http.ml] for hook rationale — drain
         wakeup on [Sse.unregister]. *)
      Sse.set_disconnect_hook session_id (fun () ->
        stop_sse_session session_id);
      let prime =
        Ag_ui.(
          make_event ~thread_id:default_thread_id ~run_id:(Some session_id) Run_started
          |> event_to_sse)
      in
      if not (send_raw info prime) then
        Log.Server.debug "ag-ui prime send failed for session %s" info.session_id;
      (match last_event_id with
      | Some last_id ->
          let missed = Sse.get_events_after_for_kind Sse.Observer last_id in
          List.iter (fun ev ->
            if not (send_raw info ev) then
              Log.Server.debug "ag-ui replay send failed for session %s" info.session_id
          ) missed
      | None -> ());
      (match deps.get_runtime_result () with
      | Ok runtime ->
          let sw = runtime.sw in
          let clock = runtime.clock in
          (* Drain fiber for per-session event stream *)
          Eio.Fiber.fork ~sw (fun () ->
              let rec drain () =
                let event = Eio.Stream.take event_stream in
                (try
                  if not (info.closed || !(info.stop)) then
                    if not (send_raw info event) then
                      Log.Server.debug "ag-ui drain send failed for session %s"
                        info.session_id
                with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                  Log.Server.error "ag-ui drain write error: %s"
                    (Printexc.to_string exn);
                  stop_sse_session_preserve_guard info.session_id);
                if not !(info.stop) then drain ()
              in
              try drain ()
              with Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Server.error "ag-ui drain loop error: %s"
                     (Printexc.to_string exn));
          (* Ping fiber *)
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                if not !(info.stop) then (
                  (try Eio.Time.sleep clock sse_ping_interval_s
                   with Eio.Cancel.Cancelled _ as exn -> raise exn
                      | exn -> Log.Server.debug "SSE ping sleep interrupted: %s" (Printexc.to_string exn));
                  (try
                     if info.closed then
                       stop_sse_session_preserve_guard info.session_id
                     else if not !(info.stop) then
                       if not (send_raw info ": ping\n\n") then
                         Log.Server.debug "ag-ui ping send failed for session %s"
                           info.session_id
                   with Eio.Cancel.Cancelled _ as exn -> raise exn
                      | exn ->
                          Log.Server.warn "SSE ping send failed for session %s: %s" info.session_id (Printexc.to_string exn);
                          stop_sse_session_preserve_guard info.session_id);
                  loop ())
              in
              try loop () with Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                    Log.Server.error "SSE ping loop exited for session %s: %s" info.session_id (Printexc.to_string exn);
                    stop_sse_session_preserve_guard info.session_id)
      | Error msg ->
          Log.Server.debug "ag-ui SSE runtime unavailable for session %s: %s"
            session_id msg)

let handle_presence_events ~deps request reqd =
  let origin = deps.get_origin request in
  let raw_session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let session_id = presence_session_id raw_session_id in
  let protocol_version =
    get_protocol_version_for_session ~session_id:raw_session_id request
  in
  let base_path = deps.get_base_path () in
  match deps.verify_mcp_observer_stream_auth ~base_path request with
  | Error msg ->
      respond_mcp_auth_error ~deps request reqd ~session_id:raw_session_id
        ~protocol_version msg
  | Ok () -> (
      match check_sse_connect_guard session_id with
      | Error (reason, retry_after_s) ->
          respond_sse_rate_limited ~deps ~origin ~session_id
            ~protocol_version ~reason ~retry_after_s reqd
      | Ok () ->
          stop_sse_session_preserve_guard session_id;
          let headers =
            presence_stream_headers ~deps raw_session_id protocol_version origin
          in
          let response = Httpun.Response.create ~headers `OK in
          let writer = Httpun.Reqd.respond_with_streaming reqd response in
          let mutex = Eio.Mutex.create () in
          let client_id, event_stream, evicted =
            Sse.register ~kind:Sse.Presence session_id ~last_event_id:0
          in
          (match evicted with
          | Some evicted_sid -> stop_sse_session evicted_sid
          | None -> ());
          let info =
            {
              session_id;
              client_id;
              writer;
              mutex;
              stop = ref false;
              closed = false;
            }
          in
          register_sse_conn ~session_id ~info;
          (* Presence streams use the preserve-guard variant of stop, so
             the disconnect hook delegates to [stop_sse_session_preserve_guard]
             instead of [stop_sse_session] to keep the connect-rate guard
             across reconnects (see this module's docstring for why). *)
          Sse.set_disconnect_hook session_id (fun () ->
            stop_sse_session_preserve_guard session_id);
          if not (send_raw info ": presence-stream\nretry: 3000\n\n") then
            Log.Server.debug "presence prime send failed for session %s"
              info.session_id;
          match deps.get_runtime_result () with
          | Ok runtime ->
              let sw = runtime.sw in
              let clock = runtime.clock in
              Eio.Fiber.fork ~sw (fun () ->
                  let rec drain () =
                    let event = Eio.Stream.take event_stream in
                    (try
                       if not (info.closed || !(info.stop)) then
                         if not (send_raw info event) then
                           Log.Server.debug
                             "presence drain send failed for session %s"
                             info.session_id
                     with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                         Log.Server.error "presence drain write error: %s"
                           (Printexc.to_string exn);
                         stop_sse_session_preserve_guard info.session_id);
                    if not !(info.stop) then drain ()
                  in
                  try drain ()
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error "presence drain loop error: %s"
                        (Printexc.to_string exn));
              Eio.Fiber.fork ~sw (fun () ->
                  let rec loop () =
                    if not !(info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                           Log.Server.debug
                             "presence ping sleep interrupted: %s"
                             (Printexc.to_string exn));
                      (try
                         if info.closed then
                           stop_sse_session_preserve_guard info.session_id
                         else if not !(info.stop) then
                           if not (send_raw info ": ping\n\n") then
                             Log.Server.debug
                               "presence ping send failed for session %s"
                               info.session_id
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
                        info.session_id (Printexc.to_string exn))
          | Error msg ->
              Log.Server.debug
                "presence SSE runtime unavailable for session %s: %s"
                session_id msg)
