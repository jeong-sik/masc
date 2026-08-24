type 'request t =
  | Sends
  | Queues_behind of 'request
  | Refused_prepared of 'request
  | Refused_cleanup of 'request
  | Refused_recovery_blocked of string
  | Refused_unverified of 'request

let of_state ~prepared ~cleanup_pending ~recovery_blocked ~inflight ~unverified
    =
  match prepared with
  | Some request -> Refused_prepared request
  | None ->
  match cleanup_pending with
  | Some request -> Refused_cleanup request
  | None ->
  match recovery_blocked with
  | Some detail -> Refused_recovery_blocked detail
  | None ->
  match inflight with
  (* A turn is running and nothing durable is blocking, so Enter holds the
     line rather than refusing it: the operator meant "send this next", and
     the turn settling is what next is. *)
  | Some request -> Queues_behind request
  | None ->
  match unverified with
  | Some request -> Refused_unverified request
  | None -> Sends
