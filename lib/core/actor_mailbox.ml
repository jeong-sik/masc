type 'msg t = 'msg Actor_types.t

let default_capacity = 64

let create ?(capacity = default_capacity) name =
  if capacity < 1 then
    invalid_arg
      (Printf.sprintf
         "Actor_mailbox.create: capacity must be >= 1, got %d" capacity);
  let inbox = Eio.Stream.create capacity in
  { Actor_types.name; inbox; stop_signal = Atomic.make false }

let send (t : 'msg t) (msg : 'msg) : unit =
  Eio.Stream.add t.Actor_types.inbox msg

let length (t : 'msg t) : int =
  Eio.Stream.length t.Actor_types.inbox

let stop (t : 'msg t) : unit =
  Atomic.set t.Actor_types.stop_signal true

let run (t : 'msg t) ~init
    ~(handle : 'state -> 'msg -> 'state * Actor_types.handler_outcome) : unit =
  let rec loop state =
    if Atomic.get t.Actor_types.stop_signal then ()
    else
      let msg = Eio.Stream.take t.Actor_types.inbox in
      let state', outcome = handle state msg in
      match outcome with
      | Actor_types.Continue -> loop state'
      | Actor_types.Stop -> ()
  in
  loop init
