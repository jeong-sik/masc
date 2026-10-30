let max_queued_events = 64
let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

(* A client that reads takes a frame at once. One that has not accepted a frame
   after this many keepalive intervals has stopped reading, or its connection is
   half open. *)
let stalled_after_ping_intervals = 3.0
let stalled_after_s = stalled_after_ping_intervals *. ping_interval_s

(* Httpun adds no Content-Length to a streaming body, so closing the writer is
   the only end of the response; advertising keep-alive would make a client
   wait for an end that cannot be framed (same as [keeper_chat_stream_headers]). *)
let response_headers =
  Httpun.Headers.of_list
    [ "content-type", "text/event-stream"
    ; "cache-control", "no-cache"
    ; "connection", "close"
    ; "x-accel-buffering", "no"
    ]
;;

let serve ~sw ~clock ~subscribe ~ping_interval_s ~stalled_after_s ~max_queued_events reqd =
  let response = Httpun.Response.create ~headers:response_headers `OK in
  let writer =
    Httpun.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response
  in
  (* Waits until the bytes reach the socket, so a client that stops reading
     holds the pump here and its queue fills up to the bound, instead of the
     writer's buffer growing without one. *)
  let send data =
    if Httpun.Body.Writer.is_closed writer
    then false
    else (
      Httpun.Body.Writer.write_string writer data;
      let flushed, resolve = Eio.Promise.create () in
      Httpun.Body.Writer.flush writer (Eio.Promise.resolve resolve);
      match Eio.Promise.await flushed with
      | `Written -> true
      | `Closed -> false)
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun stream_sw ->
      Server_bootstrap_http.with_cleanups_on_release
        ~sw:stream_sw
        [ (fun () ->
            if not (Httpun.Body.Writer.is_closed writer)
            then Httpun.Body.Writer.close writer)
        ];
      match
        Server_fleet_stream_pump.run
          ~subscribe
          ~clock
          ~ping_interval_s
          ~stalled_after_s
          ~max_queued_events
          ~send
      with
      | Server_fleet_stream_pump.Client_gone -> ()
      | Server_fleet_stream_pump.Fell_behind ->
        Log.Server.warn
          "Fleet stream closed: the client was %d events behind"
          max_queued_events
      | Server_fleet_stream_pump.Stalled ->
        Log.Server.warn
          "Fleet stream closed: the client accepted no frame for %.0f seconds"
          stalled_after_s
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
        Log.Server.warn "Fleet stream failed: %s" (Printexc.to_string exn)))
;;

let add_routes ~sw ~clock router =
  router
  |> Server_route.get
       Server_route.Public_read
       Fleet_stream.stream_path
       (fun _state _request reqd ->
          serve
            ~sw
            ~clock
            ~subscribe:(Fleet_stream_hub.subscribe Server_routes_http_runtime.fleet_stream_hub)
            ~ping_interval_s
            ~stalled_after_s
            ~max_queued_events
            reqd)
;;
