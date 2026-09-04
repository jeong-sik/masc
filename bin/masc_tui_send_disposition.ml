type 'request t =
  | Sends
  | Queues_behind of 'request

let of_state ~inflight ~waiting =
  match inflight with
  (* A turn is running, so Enter holds the line rather than refusing it: the
     operator meant "send this next", and the turn settling is what next is. *)
  | Some request -> Queues_behind request
  | None ->
    (match waiting with
     (* No turn is running, but a line is already waiting for this keeper -- one
        that has not dispatched yet because the operator is still composing the
        next. Enter joins that line rather than sending past it, so two lines
        typed as one thought arrive together and in order. Without this the
        free-keeper path would dispatch the new line straight away and overtake
        the one still queued. *)
     | Some request -> Queues_behind request
     | None -> Sends)
