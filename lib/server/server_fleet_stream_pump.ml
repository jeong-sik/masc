type ending =
  | Client_gone
  | Fell_behind

type wake =
  | Event of Fleet_stream.event
  | Ping

let keepalive_frame = ": keepalive\n\n"

let frame event =
  let revision = Fleet_stream.Revision.to_int (Fleet_stream.revision_of_event event) in
  Sse_wire.format_event_yojson ~id:revision (Fleet_stream.encode event)
;;

let run ~subscribe ~clock ~ping_interval_s ~max_queued_events ~send =
  let queue = Eio.Stream.create max_queued_events in
  let behind = Atomic.make false in
  (* The hub calls this with its lock held and expects it to return at once, so
     it never waits for room: a full queue marks the connection and the loop
     below ends it. The hub serializes its callbacks, and only the loop takes
     from the queue, so the length read here cannot grow before the [add]. *)
  let on_event event =
    if Eio.Stream.length queue >= max_queued_events
    then Atomic.set behind true
    else Eio.Stream.add queue event
  in
  let rec serve () =
    if Atomic.get behind
    then Fell_behind
    else (
      (* An event taken as the keepalive came due is that event: it has left
         the queue, and a keepalive written in its place would drop it. *)
      match
        Watched_work.run
          ~watcher:(fun () ->
            Eio.Time.sleep clock ping_interval_s;
            Ping)
          (fun () -> Event (Eio.Stream.take queue))
      with
      | Event event -> if send (frame event) then serve () else Client_gone
      | Ping -> if send keepalive_frame then serve () else Client_gone)
  in
  Eio.Switch.run (fun sw ->
    (* Nothing between subscribing and registering the removal can be
       cancelled, so a cancelled client cannot leave its subscription behind. *)
    let unsubscribe = subscribe ~on_event in
    Eio.Switch.on_release sw unsubscribe;
    serve ())
;;
