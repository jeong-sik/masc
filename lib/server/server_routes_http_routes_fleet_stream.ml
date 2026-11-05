let max_queued_events = 64
let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s
let stalled_after_s = Server_mcp_transport_http_headers.sse_stalled_after_s

let frame event =
  let revision = Fleet_stream.Revision.to_int (Fleet_stream.revision_of_event event) in
  Sse_wire.format_event_yojson ~id:revision (Fleet_stream.encode event)
;;

(* Httpun adds no Content-Length to a streaming body, so closing the writer is
   the only end of the response; advertising keep-alive would make a client
   wait for an end that cannot be framed (same as [keeper_chat_stream_headers]). *)
let response_headers () =
  Httpun.Headers.of_list
    (Http_server_eio.Response.scoped_headers ()
     @ [ "content-type", "text/event-stream"
    ; "cache-control", "no-cache"
    ; "connection", "close"
    ; "x-accel-buffering", "no"
    ])
;;

let serve ?(scope_is_current = fun () -> true) ?scope_replaced
    ~sw ~clock ~subscribe ~ping_interval_s ~stalled_after_s ~max_queued_events reqd =
  let response =
    Server_sse_response.respond ~clock ~stalled_after_s ~flush_headers_immediately:true reqd
      (Httpun.Response.create ~headers:(response_headers ()) `OK)
  in
  let send data : Server_sse_response.outcome =
    if scope_is_current ()
    then Server_sse_response.send response data
    else (
      Server_sse_response.close response;
      Closed)
  in
  (* [sw] lives as long as the server, so a failure of this one stream,
     subscribing included, is logged here instead of failing it. *)
  Eio.Fiber.fork ~sw (fun () ->
    match
      Eio.Switch.run (fun stream_sw ->
        Server_bootstrap_http.with_cleanups_on_release
          ~sw:stream_sw
          [ (fun () -> Server_sse_response.close response) ];
        let queue = Server_sse_pump.Queue.create ~max_queued_events in
        (* Nothing between subscribing and registering the removal can be
           cancelled, so a cancelled stream cannot leave its subscription
           behind. *)
        let unsubscribe = subscribe ~on_event:(Server_sse_pump.Queue.push queue) in
        Eio.Switch.on_release stream_sw unsubscribe;
        let pump () =
          Server_sse_pump.run ~queue
            ~step:(fun event -> Server_sse_pump.Send (frame event))
            ~idle:(fun () -> Server_sse_pump.Keepalive)
            ~clock ~ping_interval_s ~send
        in
        match scope_replaced with
        | None -> `Ended (pump ())
        | Some replaced ->
          Eio.Fiber.first
            (fun () -> Eio.Promise.await replaced; `Scope_replaced)
            (fun () -> `Ended (pump ())))
    with
    (* [Server_sse_response.send] logs a stalled frame with the request path. *)
    | `Scope_replaced
    | `Ended (Server_sse_pump.Client_gone | Server_sse_pump.Stalled | Server_sse_pump.Finished) -> ()
    | `Ended Server_sse_pump.Fell_behind ->
      Log.Server.warn
        "Fleet stream closed: the client was %d events behind"
        max_queued_events
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Log.Server.warn "Fleet stream failed: %s" (Printexc.to_string exn))
;;

let add_routes ~sw ~clock router =
  router
  |> Server_route.get
       Server_route.Public_read
       Fleet_stream.stream_path
       (fun state request reqd ->
          let scope = Mcp_server.workspace_scope state in
          let scope_is_current () =
            Option.exists (fun active -> active == state) (Server_auth.current_server_state ())
            && Mcp_server.Workspace_scope_epoch.equal scope.epoch
                 (Mcp_server.workspace_scope state).epoch
          in
          let refuse error =
            let json, status = Server_auth.read_workspace_precondition_error_response error in
            Http_server_eio.Response.json_value ~status ~request json reqd
          in
          match Server_auth.validate_read_workspace_precondition ~config:scope.config request with
          | Error error -> refuse error
          | Ok _ ->
          match Server_routes_http_runtime.fleet_stream_hub_for_scope ~state ~scope with
          | None -> refuse Workspace.Workspace_precondition_failed
          | Some _ when not (scope_is_current ()) ->
              refuse Workspace.Workspace_precondition_failed
          | Some hub ->
          let subscribe ~on_event =
            Fleet_stream_hub.subscribe hub ~on_event:(fun event ->
              if scope_is_current () then on_event event)
          in
          serve ~scope_is_current
            ~scope_replaced:(Mcp_server.workspace_scope_replaced scope)
            ~sw
            ~clock
            ~subscribe
            ~ping_interval_s
            ~stalled_after_s
            ~max_queued_events
            reqd)
;;
