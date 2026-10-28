open Server_auth
module Http = Http_server_eio

let max_queued_events = 64
let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

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

let serve ~sw ~clock ~subscribe ~ping_interval_s ~max_queued_events reqd =
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
          ~max_queued_events
          ~send
      with
      | Server_fleet_stream_pump.Client_gone -> ()
      | Server_fleet_stream_pump.Fell_behind ->
        Log.Server.warn
          "Fleet stream closed: the client was %d events behind"
          max_queued_events
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
        Log.Server.warn "Fleet stream failed: %s" (Printexc.to_string exn)))
;;

let add_routes ~sw ~clock router =
  router
  |> Http.Router.get Fleet_stream.stream_path (fun request reqd ->
    with_public_read
      (fun _state _request reqd ->
         serve
           ~sw
           ~clock
           ~subscribe:(Fleet_stream_hub.subscribe Server_routes_http_runtime.fleet_stream_hub)
           ~ping_interval_s
           ~max_queued_events
           reqd)
      request
      reqd)
;;
