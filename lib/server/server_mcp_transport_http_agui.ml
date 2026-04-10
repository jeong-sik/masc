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
        (fun l -> String.length l > 6 && String.sub l 0 6 = "data: ")
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

let handle_ag_ui_events ~deps request reqd =
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let _room_id_legacy = query_param request "room" in  (* ignored — namespace retired *)
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
      stop_sse_session session_id;
      let headers =
        Httpun.Headers.of_list
          (sse_stream_headers ~deps session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `OK in
      let writer = Httpun.Reqd.respond_with_streaming reqd response in
      let mutex = Eio.Mutex.create () in
      let info_ref : sse_conn_info option ref = ref None in
      let push event =
        match !info_ref with
        | None -> ()
        | Some info -> ignore (send_raw info (ag_ui_event_of_masc_event event))
      in
      let client_id, event_stream, evicted =
        Sse.register session_id ~push
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
      let prime =
        Ag_ui.(
          make_event ~thread_id:"default" ~run_id:(Some session_id) Run_started
          |> event_to_sse)
      in
      ignore (send_raw info prime);
      (match last_event_id with
      | Some last_id ->
          let missed = Sse.get_events_after last_id in
          List.iter (fun ev -> ignore (send_raw info ev)) missed
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
                    ignore (send_raw info event)
                with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                  Log.Server.error "ag-ui drain write error: %s"
                    (Printexc.to_string exn);
                  stop_sse_session info.session_id);
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
                       stop_sse_session info.session_id
                     else if not !(info.stop) then
                       ignore (send_raw info ": ping\n\n")
                   with Eio.Cancel.Cancelled _ as exn -> raise exn
                      | exn ->
                          Log.Server.warn "SSE ping send failed for session %s: %s" info.session_id (Printexc.to_string exn);
                          stop_sse_session info.session_id);
                  loop ())
              in
              try loop () with Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                    Log.Server.error "SSE ping loop exited for session %s: %s" info.session_id (Printexc.to_string exn);
                    stop_sse_session info.session_id)
      | Error msg ->
          Log.Server.debug "ag-ui SSE runtime unavailable for session %s: %s"
            session_id msg)
