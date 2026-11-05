type ending =
  | Client_gone
  | Fell_behind
  | Stalled
  | Finished

type step =
  | Skip
  | Send of string
  | Send_last of string
  | Stop

type idle =
  | Keepalive
  | Quiet
  | Finish

type 'event wake =
  | Event of 'event
  | Ping

let keepalive_frame = ": keepalive\n\n"
let max_batch_bytes = 65_536

module Queue = struct
  type 'event t =
    { events : 'event Eio.Stream.t
    ; capacity : int
    ; reserved : int Atomic.t
    ; behind : bool Atomic.t
    }

  let create ~max_queued_events =
    { events = Eio.Stream.create max_queued_events
    ; capacity = max_queued_events
    ; reserved = Atomic.make 0
    ; behind = Atomic.make false
    }
  ;;

  (* A slot is reserved before the add and given back after the take, so the
     stream never holds more than [capacity] events and [add] never waits,
     however many producers push at once and from whichever domain. *)
  let push t event =
    if Atomic.fetch_and_add t.reserved 1 < t.capacity
    then Eio.Stream.add t.events event
    else (
      Atomic.decr t.reserved;
      Atomic.set t.behind true)
  ;;

  (* Nothing between the take and the release suspends, so a cancelled take
     either took nothing or keeps its event. *)
  let take t =
    let event = Eio.Stream.take t.events in
    Atomic.decr t.reserved;
    event
  ;;

  let take_nonblocking t =
    match Eio.Stream.take_nonblocking t.events with
    | None -> None
    | Some event ->
      Atomic.decr t.reserved;
      Some event
  ;;

  let fell_behind t = Atomic.get t.behind
end

let run ~queue ~step ~idle ~clock ~ping_interval_s ~send =
  let rec serve () =
    if Queue.fell_behind queue
    then Fell_behind
    else (
      (* An event taken as the interval ran out is that event: it has left
         the queue, and the idle answer used in its place would drop it.
         [Watched_work.run] keeps the work's outcome. *)
      match
        Watched_work.run
          ~watcher:(fun () ->
            Eio.Time.sleep clock ping_interval_s;
            Ping)
          (fun () -> Event (Queue.take queue))
      with
      | Event event ->
        (match step event with
         | Skip -> serve ()
         | Send frame -> batch [ frame ] ~bytes:(String.length frame)
         | Send_last frame -> after_send ~last:true (send frame)
         | Stop -> Finished)
      | Ping ->
        (match idle () with
         | Keepalive -> after_send ~last:false (send keepalive_frame)
         | Quiet -> serve ()
         | Finish -> Finished))
  (* The events already queued go out in the same send, so a burst waits for
     the socket once per batch instead of once per frame. Each take first
     looks for a pile-up: a frame for an event queued after a dropped one is
     never written. *)
  and batch frames ~bytes =
    let write ~last frames = after_send ~last (send (String.concat "" (List.rev frames))) in
    if bytes >= max_batch_bytes || Queue.fell_behind queue
    then write ~last:false frames
    else
      match Queue.take_nonblocking queue with
      | None -> write ~last:false frames
      | Some event ->
        (match step event with
         | Skip -> batch frames ~bytes
         | Send frame -> batch (frame :: frames) ~bytes:(bytes + String.length frame)
         | Send_last frame -> write ~last:true (frame :: frames)
         | Stop -> write ~last:true frames)
  and after_send ~last : Server_sse_response.outcome -> ending = function
    | Written -> if last then Finished else serve ()
    | Closed -> Client_gone
    | Stalled -> Stalled
  in
  serve ()
;;
