(** Server_mcp_transport_http_agui — AG-UI SSE bridge handler. *)

open Server_mcp_transport_http_protocol
open Server_mcp_transport_http_conn
open Server_mcp_transport_http_respond

module Sse_owner = Server_mcp_transport_http_sse_owner

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

let with_owned_sse_admission ~deps ~request ~reqd ~origin ~session_id
      ?related_transport_session_id ~response_session_id ~sse_kind on_admitted =
  let base_path = deps.get_base_path () in
  let fallback_protocol_version = get_protocol_version request in
  match
    Server_auth.authorize_token_bound_admission_request ~base_path
      ~permission:Masc_domain.CanReadState request
  with
  | Error err ->
      respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps request reqd
        ~session_id:response_session_id
        ~protocol_version:fallback_protocol_version
        (Masc_domain.masc_error_to_string err)
  | Ok admission -> (
      match deps.get_mcp_http_transport () with
      | Error message ->
          Log.Server.error "MCP HTTP transport unavailable: %s" message;
          respond_not_ready ~deps request reqd
      | Ok transport -> (
          let protocol_version =
            get_protocol_version_for_session
              ~sessions:(Sse_owner.sessions transport)
              ~session_id:response_session_id request
          in
          match
            Sse_owner.claim_mcp_sse_session_owner_for_request transport
              ~session_id ?lifecycle_session_id:related_transport_session_id
              ~sse_kind ~requester:admission.identity
          with
          | Error msg ->
              respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps request
                reqd ~session_id:response_session_id ~protocol_version msg
          | Ok lease -> (
          match check_sse_connect_guard session_id with
          | Error (reason, retry_after_s) ->
              Sse_owner.release transport lease;
              respond_sse_rate_limited ~deps ~origin ~session_id
                ~protocol_version ~reason ~retry_after_s reqd
          | Ok () -> (
              match
                Sse_owner.ensure_backing_session_for_owner transport ~session_id
                  ~requester:admission.identity
              with
              | Error msg ->
                  Sse_owner.release transport lease;
                  respond_mcp_error ~code:Mcp_error_code.Auth_error ~deps
                    request reqd ~session_id:response_session_id
                    ~protocol_version msg
              | Ok () ->
                  on_admitted transport base_path admission lease
                    protocol_version))))

let register_owned_sse ~deps ~reqd ~origin ~session_id
      ~protocol_version ~sse_kind ~last_event_id ~transport ~base_path
      ~admission ~lease ~headers on_connected =
  let registered_client_id = ref None in
  let release () = Sse_owner.release transport lease in
  let cleanup_failed_setup () =
    match !registered_client_id with
    | Some client_id ->
        stop_sse_session_if_current_preserve_guard session_id client_id;
        Sse.unregister_if_current session_id client_id;
        release ()
    | None -> release ()
  in
  try
    match Sse_owner.commit_previous_retirement transport lease with
    | Error msg ->
        release ();
        Log.Server.warn "%s" msg;
        respond_sse_register_error ~deps ~origin ~protocol_version reqd msg
    | Ok previous_client_id ->
      Option.iter
        (fun client_id ->
          stop_sse_session_if_current_preserve_guard session_id client_id;
          Sse.unregister_if_current session_id client_id)
        previous_client_id;
      let auth =
        { Sse.config = base_path; token = Some admission.auth_token }
      in
      (match
         Sse.register ~kind:sse_kind
           ~precondition:Sse.No_current_client ~auth session_id ~last_event_id
           ~on_disconnect:(fun disconnected_client_id ->
             release ();
             stop_sse_session_if_current_preserve_guard session_id
               disconnected_client_id)
       with
       | Error reg_err ->
           release ();
           let msg = Sse.registration_error_to_string reg_err in
           Log.Server.warn "%s" msg;
           respond_sse_register_error ~deps ~origin ~protocol_version reqd msg
       | Ok (client_id, event_stream, evicted) ->
        registered_client_id := Some client_id;
        let response = Httpun.Response.create ~headers `OK in
        let writer = Httpun.Reqd.respond_with_streaming reqd response in
        let mutex = Eio.Mutex.create () in
        (match evicted with
        | Some evicted_sid ->
            stop_sse_session_evict evicted_sid
              ~reason:Session_lifecycle_event.Cap_exceeded
        | None -> ());
        let info = make_sse_conn ~session_id ~client_id ~writer ~mutex () in
        if not (register_sse_conn_if_absent ~session_id ~info) then (
          close_sse_conn info;
          release ();
          Log.Server.warn
            "SSE connection publication superseded for session %s client=%d"
            session_id client_id)
        else
          match Sse_owner.activate transport lease ~client_id with
          | Error msg ->
              cleanup_failed_setup ();
              Log.Server.warn
                "SSE owner activation failed after connection publication for %s: %s"
                session_id msg
          | Ok () -> on_connected info event_stream)
  with
  | Eio.Cancel.Cancelled _ as e ->
      cleanup_failed_setup ();
      raise e
  | exn ->
      cleanup_failed_setup ();
      raise exn

let handle_ag_ui_events ~deps request reqd =
  if not (deps.is_ready ()) then respond_not_ready ~deps request reqd
  else
  let origin = deps.get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  (* workspace query param ignored — namespace retired *)
  let last_event_id =
    match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
    | Some id -> int_of_string_opt id
    | None -> None
  in
  with_owned_sse_admission ~deps ~request ~reqd ~origin ~session_id
    ~response_session_id:session_id ~sse_kind:Sse.Observer
    (fun transport base_path admission lease protocol_version ->
      let headers =
        Httpun.Headers.of_list
          (sse_stream_headers ~deps session_id protocol_version origin)
      in
      register_owned_sse ~deps ~reqd ~origin ~session_id ~transport
        ~protocol_version ~sse_kind:Sse.Observer
        ~last_event_id:(Option.value ~default:0 last_event_id) ~base_path
        ~admission ~lease ~headers (fun info event_stream ->
          if Option.is_some last_event_id then
            Transport_metrics.inc_sse_reconnect ();
          let prime =
            Ag_ui.(
              make_event ~thread_id:default_thread_id
                ~run_id:(Some session_id) Run_started
              |> event_to_sse)
          in
          if not (send_raw info prime) then
            Log.Server.debug "ag-ui prime send failed for session %s"
              info.session_id;
          (match last_event_id with
          | Some last_id ->
              let missed =
                Sse.get_events_after_for_kind Sse.Observer last_id
              in
              List.iter
                (fun event ->
                  if not (send_raw info event) then
                    Log.Server.debug
                      "ag-ui replay send failed for session %s"
                      info.session_id)
                missed
          | None -> ());
          match deps.get_runtime_result () with
          | Ok runtime ->
              let sw = runtime.sw in
              let clock = runtime.clock in
              run_sse_pumps ~sw ~stop_promise:info.stop_promise
                ~drain:(fun () ->
                  let rec drain () =
                    let event = Eio.Stream.take event_stream in
                    (try
                       if
                         not
                           (Atomic.get info.closed || Atomic.get info.stop)
                       then if not (send_raw info event) then
                         Log.Server.debug
                           "ag-ui drain send failed for session %s"
                           info.session_id
                     with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Server.error "ag-ui drain write error: %s"
                          (Printexc.to_string exn);
                        stop_sse_session_if_current_preserve_guard
                          info.session_id info.client_id);
                    if not (Atomic.get info.stop) then drain ()
                  in
                  try drain () with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error "ag-ui drain loop error: %s"
                        (Printexc.to_string exn))
                ~ping:(fun () ->
                  let rec loop () =
                    if not (Atomic.get info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                          Log.Server.debug
                            "AG-UI SSE ping sleep interrupted: %s"
                            (Printexc.to_string exn));
                      (try
                         if Atomic.get info.closed then
                           stop_sse_session_if_current_preserve_guard
                             info.session_id info.client_id
                         else if not (Atomic.get info.stop) then
                           if not (send_raw info ": ping\n\n") then
                             Log.Server.debug
                               "ag-ui ping send failed for session %s"
                               info.session_id
                       with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                          Log.Server.warn
                            "AG-UI SSE ping send failed for session %s: %s"
                            info.session_id (Printexc.to_string exn);
                          stop_sse_session_if_current_preserve_guard
                            info.session_id info.client_id);
                      loop ())
                  in
                  try loop () with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error
                        "AG-UI SSE ping loop exited for session %s: %s"
                        info.session_id (Printexc.to_string exn))
          | Error msg ->
              Log.Server.error
                "AG-UI SSE runtime unavailable after registration for session %s: %s"
                session_id msg;
              stop_sse_session_if_current_preserve_guard session_id
                info.client_id))
let handle_presence_events ~deps request reqd =
  if not (deps.is_ready ()) then respond_not_ready ~deps request reqd
  else
  let origin = deps.get_origin request in
  let raw_session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let session_id = presence_session_id raw_session_id in
  with_owned_sse_admission ~deps ~request ~reqd ~origin ~session_id
    ~related_transport_session_id:raw_session_id
    ~response_session_id:raw_session_id ~sse_kind:Sse.Presence
    (fun transport base_path admission lease protocol_version ->
      let headers =
        presence_stream_headers ~deps raw_session_id protocol_version origin
      in
      register_owned_sse ~deps ~reqd ~origin ~session_id ~transport
        ~protocol_version ~sse_kind:Sse.Presence ~last_event_id:0 ~base_path
        ~admission ~lease ~headers (fun info event_stream ->
          if
            not
              (send_raw info
                 (Server_mcp_transport_http_headers.sse_comment_with_retry
                    ~comment:"presence-stream"))
          then
            Log.Server.debug "presence prime send failed for session %s"
              info.session_id;
          match deps.get_runtime_result () with
          | Ok runtime ->
              let sw = runtime.sw in
              let clock = runtime.clock in
              run_sse_pumps ~sw ~stop_promise:info.stop_promise
                ~drain:(fun () ->
                  let rec drain () =
                    let event = Eio.Stream.take event_stream in
                    (try
                       if
                         not
                           (Atomic.get info.closed || Atomic.get info.stop)
                       then if not (send_raw info event) then
                         Log.Server.debug
                           "presence drain send failed for session %s"
                           info.session_id
                     with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Server.error "presence drain write error: %s"
                          (Printexc.to_string exn);
                        stop_sse_session_if_current_preserve_guard
                          info.session_id info.client_id);
                    if not (Atomic.get info.stop) then drain ()
                  in
                  try drain () with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error "presence drain loop error: %s"
                        (Printexc.to_string exn))
                ~ping:(fun () ->
                  let rec loop () =
                    if not (Atomic.get info.stop) then (
                      (try Eio.Time.sleep clock sse_ping_interval_s with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                          Log.Server.debug
                            "presence ping sleep interrupted: %s"
                            (Printexc.to_string exn));
                      (try
                         if Atomic.get info.closed then
                           stop_sse_session_if_current_preserve_guard
                             info.session_id info.client_id
                         else if not (Atomic.get info.stop) then
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
                          stop_sse_session_if_current_preserve_guard
                            info.session_id info.client_id);
                      loop ())
                  in
                  try loop () with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Server.error
                        "presence ping loop exited for session %s: %s"
                        info.session_id (Printexc.to_string exn))
          | Error msg ->
              Log.Server.error
                "Presence SSE runtime unavailable after registration for session %s: %s"
                session_id msg;
              stop_sse_session_if_current_preserve_guard session_id
                info.client_id))
