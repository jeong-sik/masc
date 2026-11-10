let stream_path = "/api/v1/dashboard/logs/stream"
let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

(* A client that reads takes a frame at once. One that has not accepted a
   frame after this many keepalive intervals has stopped reading. *)
let stalled_after_ping_intervals = 3.0
let stalled_after_s = stalled_after_ping_intervals *. ping_interval_s

let keepalive_frame = ": keepalive\n\n"

let response_headers () =
  Httpun.Headers.of_list
    (Http_server_eio.Response.scoped_headers ()
     @ [ "content-type", "text/event-stream"
       ; "cache-control", "no-cache"
       ; "connection", "close"
       ; "x-accel-buffering", "no"
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

type ending =
  | Client_gone
  | Stalled

let serve ~sw ~clock ~config ~(query : Server_logs_query.t) reqd =
  let response = Httpun.Response.create ~headers:(response_headers ()) `OK in
  let writer =
    Http_reqd.respond_with_streaming ~flush_headers_immediately:true reqd response
  in
  (* Waits until the bytes reach the socket, so a client that stops reading
     holds the loop here instead of the writer's buffer growing. Nothing in
     this path writes a log entry: an entry would wake the loop again. *)
  let send data =
    if Http_reqd.Body_writer.is_closed writer
    then false
    else (
      Http_reqd.Body_writer.write_string writer data;
      let flushed, resolve = Eio.Promise.create () in
      Http_reqd.Body_writer.flush writer (Eio.Promise.resolve resolve);
      match Eio.Promise.await flushed with
      | `Written -> true
      | `Closed -> false)
  in
  let send_within data =
    match Eio.Time.with_timeout clock stalled_after_s (fun () -> Ok (send data)) with
    | Ok true -> Ok ()
    | Ok false -> Error Client_gone
    | Error `Timeout -> Error Stalled
  in
  let rec deliver after =
    let frame = next_frame query ~after in
    let sent =
      if worth_sending frame then send_within (sse_frame (frame_json ~config query frame))
      else Ok ()
    in
    match sent with
    | Error ending -> ending
    | Ok () -> wait frame.after
  and wait after =
    match
      Eio.Fiber.first
        (fun () ->
          Log.Ring.await_newer_than after;
          `Appended)
        (fun () ->
          Eio.Time.sleep clock ping_interval_s;
          `Quiet)
    with
    | `Appended -> deliver (Some after)
    | `Quiet ->
      (match send_within keepalive_frame with
       | Ok () -> wait after
       | Error ending -> ending)
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun stream_sw ->
      Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
        [ (fun () ->
            if not (Http_reqd.Body_writer.is_closed writer) then Http_reqd.Body_writer.close writer)
        ];
      (* One line when the stream ends badly; the loop has stopped, so it
         wakes only the other streams, once. *)
      match deliver query.since_seq with
      | Client_gone -> ()
      | Stalled ->
        Log.Server.warn "Log stream closed: the client accepted no frame for %.0f seconds"
          stalled_after_s
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn -> Log.Server.warn "Log stream failed: %s" (Printexc.to_string exn)))
;;

let add_routes ~sw ~clock router =
  router
  |> Server_route.get Server_route.Public_read stream_path (fun state request reqd ->
    match Server_logs_query.of_request request with
    | Error json ->
      Http_server_eio.Response.json_value ~status:`Bad_request ~request json reqd
    | Ok query -> serve ~sw ~clock ~config:(Mcp_server.workspace_config state) ~query reqd)
;;
