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
         | Send frame -> after_send ~last:false (send frame)
         | Send_last frame -> after_send ~last:true (send frame)
         | Stop -> Finished)
      | Ping ->
        (match idle () with
         | Keepalive -> after_send ~last:false (send keepalive_frame)
         | Quiet -> serve ()
         | Finish -> Finished))
  and after_send ~last : Server_sse_response.outcome -> ending = function
    | Written -> if last then Finished else serve ()
    | Closed -> Client_gone
    | Stalled -> Stalled
  in
  serve ()
;;
