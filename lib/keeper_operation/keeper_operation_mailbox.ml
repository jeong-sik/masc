type 'a t =
  { mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; items : 'a Queue.t
  ; capacity : int
  ; mutable closed : bool
  }

type add_result =
  | Added
  | Full
  | Closed

let create ~capacity =
  if capacity <= 0
  then Error "mailbox capacity must be positive"
  else
    Ok
      { mutex = Stdlib.Mutex.create ()
      ; condition = Eio.Condition.create ()
      ; items = Queue.create ()
      ; capacity
      ; closed = false
      }
;;

let with_lock t f =
  Stdlib.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mutex) f
;;

let try_add t item =
  let result =
    with_lock t (fun () ->
      if t.closed
      then Closed
      else if Queue.length t.items >= t.capacity
      then Full
      else (
        Queue.add item t.items;
        Added))
  in
  (match result with
   | Added -> Eio.Condition.broadcast t.condition
   | Full | Closed -> ());
  result
;;

let take_nonblocking t =
  with_lock t (fun () ->
    match Queue.take_opt t.items with
    | Some item -> Some (Some item)
    | None when t.closed -> Some None
    | None -> None)
;;

let take t = Eio.Condition.loop_no_mutex t.condition (fun () -> take_nonblocking t)

let close t =
  let changed =
    with_lock t (fun () ->
      if t.closed
      then false
      else (
        t.closed <- true;
        true))
  in
  if changed then Eio.Condition.broadcast t.condition
;;

let length t = with_lock t (fun () -> Queue.length t.items)
let capacity t = t.capacity
let is_closed t = with_lock t (fun () -> t.closed)
