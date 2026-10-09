type delivery = Continue | Stop

module State = struct
  type 'a queue = { front : 'a list; back : 'a list }
  type 'a t = Buffering of 'a queue | Ready | Sending of 'a queue | Closed

  let empty = { front = []; back = [] }
  let initial = Buffering empty
  let push queue value = { queue with back = value :: queue.back }

  let take queue =
    match queue.front with
    | value :: front -> Some (value, { queue with front })
    | [] ->
      match List.rev queue.back with
      | [] -> None
      | value :: front -> Some (value, { front; back = [] })

  let claim queue =
    match take queue with
    | None -> Ready, None
    | Some (value, queue) -> Sending queue, Some value

  let publish state value =
    match state with
    | Buffering queue -> Buffering (push queue value), None
    | Sending queue -> Sending (push queue value), None
    | Ready -> Sending empty, Some value
    | Closed -> Closed, None

  let accept = function
    | Buffering queue -> claim queue
    | (Ready | Sending _ | Closed) as state -> state, None

  let next = function
    | Sending queue -> claim queue
    | (Buffering _ | Ready | Closed) as state -> state, None
end

type 'a t = { mutex : Stdlib.Mutex.t; mutable state : 'a State.t }

let create () = { mutex = Stdlib.Mutex.create (); state = State.initial }

let transition t step =
  Stdlib.Mutex.protect t.mutex (fun () ->
    let state, next = step t.state in
    t.state <- state;
    next)

let close t =
  Stdlib.Mutex.protect t.mutex (fun () -> t.state <- State.Closed)

let drain t ~send first =
  let rec loop = function
    | None -> ()
    | Some value ->
      match send value with
      | Stop -> close t
      | Continue -> loop (transition t State.next)
  in
  match loop first with
  | () -> ()
  | exception exn ->
    (* Cleanup is synchronous and cannot replace a cancellation or send error. *)
    let backtrace = Printexc.get_raw_backtrace () in
    close t;
    Printexc.raise_with_backtrace exn backtrace

let publish t ~send value =
  drain t ~send (transition t (fun state -> State.publish state value))

let accept t ~send = drain t ~send (transition t State.accept)
