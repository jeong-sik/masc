type ending =
  | Client_gone
  | Fell_behind
  | Stalled

type wake =
  | Event of Fleet_stream.event
  | Ping

(* How one [send] ended: it answered, or the time allowed for it ran out. *)
type delivery =
  | Sent of bool
  | Not_accepted_in_time

let keepalive_frame = ": keepalive\n\n"

let frame event =
  let revision = Fleet_stream.Revision.to_int (Fleet_stream.revision_of_event event) in
  Sse_wire.format_event_yojson ~id:revision (Fleet_stream.encode event)
;;

let run ~subscribe ~clock ~ping_interval_s ~stalled_after_s ~max_queued_events ~send =
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
  (* A [send] that answers just as the time runs out has answered:
     [Watched_work.run] keeps the work's outcome. *)
  let deliver data =
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock stalled_after_s;
        Not_accepted_in_time)
      (fun () -> Sent (send data))
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
      | Event event -> after_send (deliver (frame event))
      | Ping -> after_send (deliver keepalive_frame))
  and after_send = function
    | Sent true -> serve ()
    | Sent false -> Client_gone
    | Not_accepted_in_time -> Stalled
  in
  Eio.Switch.run (fun sw ->
    (* Nothing between subscribing and registering the removal can be
       cancelled, so a cancelled client cannot leave its subscription behind. *)
    let unsubscribe = subscribe ~on_event in
    Eio.Switch.on_release sw unsubscribe;
    serve ())
;;
