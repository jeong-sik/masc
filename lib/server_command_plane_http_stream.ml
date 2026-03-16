open Server_command_plane_http_support

let stream_native_chain_events_http ~deps ~request reqd =
  let origin = deps.get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Log.Misc.info "%s" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (Httpun.Body.Writer.is_closed writer) then
          Httpun.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || Httpun.Body.Writer.is_closed writer then
            `Closed
          else
            try
              Httpun.Body.Writer.write_string writer frame;
              Httpun.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream
          ~reason:
            (Printf.sprintf "stream write failed: %s" (Printexc.to_string exn))
          ();
        false
  in
  (try
     let sub =
       Chain_telemetry.subscribe (fun event ->
           let payload = Chain_native_eio.chain_event_json event |> Yojson.Safe.to_string in
           let frame =
             Sse.format_event
               ~event_type:(Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (deps.get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s"
            (Printexc.to_string exn))
       ())

let proxy_chain_events_http ~deps ~request reqd =
  stream_native_chain_events_http ~deps ~request reqd

let command_plane_chain_events_http ~deps ~request reqd =
  stream_native_chain_events_http ~deps ~request reqd

let stream_native_chain_events_h2 ~deps ~request h2_reqd =
  let origin = deps.get_origin request in
  let headers =
    H2.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = H2.Response.create ~headers `OK in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
      response
  in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Log.Misc.info "%s" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (H2.Body.Writer.is_closed writer) then H2.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || H2.Body.Writer.is_closed writer then
            `Closed
          else
            try
              H2.Body.Writer.write_string writer frame;
              H2.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream
          ~reason:
            (Printf.sprintf "stream write failed: %s" (Printexc.to_string exn))
          ();
        false
  in
  (try
     let sub =
       Chain_telemetry.subscribe (fun event ->
           let payload = Chain_native_eio.chain_event_json event |> Yojson.Safe.to_string in
           let frame =
             Sse.format_event
               ~event_type:(Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (deps.get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s"
            (Printexc.to_string exn))
       ())

let proxy_chain_events_h2 ~deps ~request h2_reqd =
  stream_native_chain_events_h2 ~deps ~request h2_reqd

let command_plane_chain_events_h2 ~deps ~request h2_reqd =
  stream_native_chain_events_h2 ~deps ~request h2_reqd

