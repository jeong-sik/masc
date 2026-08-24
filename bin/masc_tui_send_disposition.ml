type 'request t =
  | Sends
  | Queues_behind of 'request

let of_state ~inflight =
  match inflight with
  (* A turn is running, so Enter holds the line rather than refusing it: the
     operator meant "send this next", and the turn settling is what next is. *)
  | Some request -> Queues_behind request
  | None -> Sends
