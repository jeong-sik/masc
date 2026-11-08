let serve ~clock ~ping_interval_s ~stalled_after_s ~max_queued_events ~subscription_id
    ~filter ~headers reqd =
  Eio.Switch.run (fun stream_sw ->
    let response =
      Server_sse_response.respond ~clock ~stalled_after_s reqd
        (Httpun.Response.create ~headers `OK)
    in
    Eio.Switch.on_release stream_sw (fun () -> Server_sse_response.close response);
    match
      Server_sse_response.send response (Server_mcp_transport_http_headers.sse_prime_event ())
    with
    | Closed | Stalled -> ()
    | Written ->
      let queue = Server_sse_pump.Queue.create ~max_queued_events in
      let ended = Atomic.make false in
      (* [Mcp_subscriptions.deliver] calls this from the publisher's fiber,
         which may be on another domain. [false] tells it the stream is over,
         and it drops the subscription. *)
      let send json =
        if Atomic.get ended
        then false
        else (
          Server_sse_pump.Queue.push queue (Sse.format_event (Yojson.Safe.to_string json));
          true)
      in
      (match
         Mcp_subscriptions.register_after_ack ~subscription_id ~filter ~send
           ~acknowledge:(fun () ->
             send (Mcp_subscriptions.acknowledgement ~subscription_id filter))
       with
       | None -> ()
       | Some token ->
         Eio.Switch.on_release stream_sw (fun () ->
           Atomic.set ended true;
           Mcp_subscriptions.unregister token);
         (match
            Server_sse_pump.run ~source:(Server_sse_pump.Queue.source queue)
              ~step:(fun frame -> Server_sse_pump.Send frame)
              ~idle:(fun () -> Server_sse_pump.Keepalive)
              ~clock ~ping_interval_s
              ~closed:(fun () -> Server_sse_response.await_closed response)
              ~send:(Server_sse_response.send response)
          with
          (* [Server_sse_response.send] logs a stalled frame with the request path. *)
          | Client_gone | Stalled | Finished -> ()
          | Source_stopped ->
            Log.Server.warn
              "subscriptions/listen stream closed: the client was %d notifications behind"
              max_queued_events)))
;;
