type deps = Server_mcp_transport_http_types.deps

let ag_ui_event_of_masc_event ~room_id event =
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
        let ag_event = Ag_ui.of_custom ~room_id ~name:"MASC_EVENT" json in
        Ag_ui.event_to_sse ag_event
    | None -> event
  with
  | Yojson.Json_error _ -> event
  | exn ->
      Log.Transport.warn "ag_ui_event_of_masc_event failed: %s" (Printexc.to_string exn);
      event

let sse_simple_handler ~(deps : deps) request reqd =
  let origin = deps.get_origin request in
  let session_id =
    Mcp_session.get_or_generate
      (Server_mcp_transport_http_session.get_session_id_any request)
  in
  let protocol_version =
    Server_mcp_transport_http_session.get_protocol_version_for_session
      ~session_id request
  in
  let event =
    Server_mcp_transport_http_headers.sse_prime_event ()
    ^ Sse.format_event ~event_type:"connected"
        (Printf.sprintf {|{"session_id":"%s"}|} session_id)
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length event))
      :: Server_mcp_transport_http_headers.legacy_transport_deprecation_headers
      @ Server_mcp_transport_http_headers.sse_headers ~deps session_id
          protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  Httpun.Reqd.respond_with_string reqd response event

let handle_ag_ui_events ~(deps : deps) request reqd =
  let origin = deps.get_origin request in
  let session_id =
    Mcp_session.get_or_generate
      (Server_mcp_transport_http_session.get_session_id_any request)
  in
  let protocol_version =
    Server_mcp_transport_http_session.get_protocol_version_for_session
      ~session_id request
  in
  let room_id =
    Option.value ~default:"default"
      (Server_mcp_transport_http_session.query_param request "room")
  in
  let last_event_id =
    Server_mcp_transport_http_headers.get_last_event_id request
  in
  match Server_mcp_transport_http_sse.check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      Server_mcp_transport_http_sse.respond_sse_rate_limited ~deps ~origin
        ~session_id ~protocol_version ~reason ~retry_after_s reqd
  | Ok () ->
      Server_mcp_transport_http_sse.stop_sse_session session_id;
      let headers =
        Httpun.Headers.of_list
          (Server_mcp_transport_http_headers.sse_stream_headers ~deps session_id
             protocol_version origin)
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
              (Server_mcp_transport_http_sse.send_raw info
                 (ag_ui_event_of_masc_event ~room_id event))
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
      Hashtbl.replace Server_mcp_transport_http_sse.sse_conn_by_session
        session_id info;
      let prime =
        Ag_ui.(
          make_event ~thread_id:room_id ~run_id:(Some session_id) Run_started
          |> event_to_sse)
      in
      ignore (Server_mcp_transport_http_sse.send_raw info prime);
      (match last_event_id with
      | Some last_id ->
          let missed = Sse.get_events_after last_id in
          List.iter
            (fun ev ->
              ignore (Server_mcp_transport_http_sse.send_raw info ev))
            missed
      | None -> ());
      (match (deps.get_sw (), deps.get_clock ()) with
      | Some sw, Some clock ->
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                if not !(info.stop) then (
                  (try
                     Eio.Time.sleep clock
                       Server_mcp_transport_http_headers.sse_ping_interval_s
                   with Eio.Cancel.Cancelled _ as exn -> raise exn | _ -> ());
                  (try
                     if info.closed then
                       Server_mcp_transport_http_sse.stop_sse_session
                         info.session_id
                     else if not !(info.stop) then
                       ignore
                         (Server_mcp_transport_http_sse.send_raw info
                            ": ping\n\n")
                   with Eio.Cancel.Cancelled _ as exn -> raise exn
                      | _ ->
                        Server_mcp_transport_http_sse.stop_sse_session
                          info.session_id);
                  loop ())
              in
              try loop () with Eio.Cancel.Cancelled _ as exn -> raise exn | _ -> ())
      | _ -> ())
