let stream_path = "/api/v1/dashboard/logs/stream"
let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

let response_headers ~instance =
  Httpun.Headers.of_list
    (Http_server_eio.Response.scoped_headers ()
     @ [ "content-type", "text/event-stream"
       ; "cache-control", "no-cache"
       ; "connection", "close"
       ; "x-accel-buffering", "no"
       ; Sse_wire.instance_header, instance
       ; Server_mcp_transport_http_headers.observer_idle_timeout_header,
         string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms
       ])
;;

type frame =
  { reset : bool
  ; entries : Log.Ring.entry list
  ; ring_bounds : Log.Ring.bounds
  ; after : int
  }

(* The entries the query selects that are newer than [after] and older than
   the sequence handed out next when the read starts, newest first. A frame
   resets the client's list when it has no cursor, when the ring evicted
   entries the client never got, or when more entries matched than the query
   takes: the client then holds the newest page, as a fresh read would give.
   [after] is the cursor for the next frame, whether or not any entry matched. *)
let next_frame (query : Server_logs_query.t) ~after =
  let ring_bounds = Log.Ring.bounds () in
  let upto = ring_bounds.total in
  let reset_cursor =
    match after with
    | None -> true
    | Some seq -> seq < ring_bounds.start_seq - 1 || seq >= upto
  in
  let since_seq = if reset_cursor then None else after in
  let entries =
    Server_logs_query.read
      { query with limit = query.limit + 1; since_seq; before_seq = Some upto }
  in
  let overflow = List.length entries > query.limit in
  let entries = if overflow then List.take query.limit entries else entries in
  let reset = reset_cursor || overflow in
  { reset; entries; ring_bounds; after = upto - 1 }
;;

let frame_json ~config (query : Server_logs_query.t) frame =
  match Server_logs_query.to_json ~config query ~ring_bounds:frame.ring_bounds frame.entries with
  | `Assoc fields -> `Assoc (("reset", `Bool frame.reset) :: fields)
  | other -> `Assoc [ "reset", `Bool frame.reset; "payload", other ]
;;

let sse_frame json = "data: " ^ Yojson.Safe.to_string json ^ "\n\n"

let worth_sending frame =
  frame.reset
  ||
  match frame.entries with
  | [] -> false
  | _ :: _ -> true
;;

let serve ~sw ~clock ~instance ~current ~replaced ~encode ~(query : Server_logs_query.t) reqd =
  let response = Httpun.Response.create ~headers:(response_headers ~instance) `OK in
  (* A frame waits until its bytes reach the socket, so a client that stops
     reading holds the loop at its send instead of the response's buffer
     growing, and a frame the client does not take ends the stream. The loop
     writes no log entry of its own: an entry would wake it again. *)
  let sse =
    Server_sse_response.respond ~clock
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~flush_headers_immediately:true reqd response
  in
  (* A keepalive is due once nothing was sent for a ping interval. The ring
     wakes the loop for every entry, also for the ones the query leaves out,
     and such a wake sends nothing: the time of the next keepalive is kept
     across it. A timer started again at each wake would never run out on a
     ring that gets an entry more often than the interval, and the stream
     would go silent for a client that still reads. [deliver] looks at the
     time itself: when the ring already holds a newer entry each time the
     loop comes back to wait, the wait for the ring returns at once and the
     wait for the time never gets its turn. *)
  let next_ping () = Eio.Time.now clock +. ping_interval_s in
  (* No byte goes out once the stream's workspace was replaced: the frame
     would carry the replaced workspace's answer. The loop ends there as it
     does for a client that is gone. [current] is read again at each send
     because the read of the ring comes before it. *)
  let send data =
    if current () then Server_sse_response.send sse data else Server_sse_response.Closed
  in
  let keepalive () = send Server_sse_pump.keepalive_frame in
  let rec deliver ~ping_at after =
    if current () then deliver_current ~ping_at after
  and deliver_current ~ping_at after =
    let frame = next_frame query ~after in
    if worth_sending frame
    then sent ~after:frame.after (send (encode frame))
    else if Eio.Time.now clock >= ping_at
    then sent ~after:frame.after (keepalive ())
    else wait ~ping_at frame.after
  and sent ~after = function
    | Server_sse_response.Written -> wait ~ping_at:(next_ping ()) after
    | Closed | Stalled -> ()
  and wait ~ping_at after =
    (* [ping_at] is a reading of the wall clock. Had the clock been set back
       since, the keepalive would be that much later than a ping interval;
       the time kept across a wake is at most one interval from now. *)
    let ping_at = Float.min ping_at (next_ping ()) in
    match
      Eio.Fiber.first
        (fun () ->
          Log.Ring.await_newer_than after;
          `Appended)
        (fun () ->
          Eio.Time.sleep_until clock ping_at;
          `Quiet)
    with
    | `Appended -> deliver ~ping_at (Some after)
    | `Quiet -> sent ~after (keepalive ())
  in
  (* A frame that stalled is logged once: by [Server_sse_response.send] on
     HTTP/1.1, by the stream's flush bound on HTTP/2. This loop is held at
     that frame's send then, so the line wakes only the other streams. The
     response ends the loop when its client is gone: a wait for the ring or
     for the keepalive time is cancelled with the HTTP/2 stream. *)
  (* [replaced] returning ends the loop too, and the response with it: a
     loop that waits for the ring would otherwise hold a replaced workspace's
     stream open until the next entry. *)
  Server_sse_response.serve ~sw sse (fun () ->
    Eio.Fiber.first replaced (fun () ->
      deliver ~ping_at:(next_ping ()) query.since_seq))
;;

let add_routes ~sw ~clock router =
  router
  |> Server_route.get Server_route.Public_read stream_path (fun state request reqd ->
    Http_server_eio.Response.with_scoped_headers
      (Http_server_eio.Response.scoped_headers () @ Server_auth.public_read_cors_headers request) (fun () ->
    match Server_logs_query.of_request request with
    | Error json ->
      Http_server_eio.Response.json_value ~status:`Bad_request ~request json reqd
    | Ok query ->
      (match Server_observer_scope.admit_stream ~state request with
       | Error error -> Server_observer_scope.refuse_stream error reqd
       | Ok owner ->
         let config = Server_observer_scope.stream_config owner in
         serve ~sw ~clock ~query reqd
           ~instance:(Server_observer_scope.stream_instance owner)
           ~current:(fun () -> Server_observer_scope.stream_is_current owner)
           ~replaced:(fun () -> Server_observer_scope.await_stream_replaced owner)
           ~encode:(fun frame -> sse_frame (frame_json ~config query frame)))))
;;
