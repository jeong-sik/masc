type ending =
  | Client_gone
  | Fell_behind
  | Stalled

type 'event wake =
  | Event of 'event
  | Ping

let keepalive_frame = ": keepalive\n\n"

let run ~subscribe ~frame ~clock ~ping_interval_s ~max_queued_events ~send =
  let queue = Eio.Stream.create max_queued_events in
  let behind = Atomic.make false in
  (* The producer calls this and expects it to return at once (the fleet hub
     holds its lock), so it never waits for room: a full queue marks the
     connection and the loop below ends it. The producer serializes its
     callbacks, and only the loop takes from the queue, so the length read
     here cannot grow before the [add]. *)
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
      | Event event -> after_send (send (frame event))
      | Ping -> after_send (send keepalive_frame))
  and after_send : Server_sse_response.outcome -> ending = function
    | Written -> serve ()
    | Closed -> Client_gone
    | Stalled -> Stalled
  in
  Eio.Switch.run (fun sw ->
    (* Nothing between subscribing and registering the removal can be
       cancelled, so a cancelled client cannot leave its subscription behind. *)
    let unsubscribe = subscribe ~on_event in
    Eio.Switch.on_release sw unsubscribe;
    serve ())
;;
