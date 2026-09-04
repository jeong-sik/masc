(** What pressing Enter in the Keeper chat composer does.

    The send path and the footer both need this answer, and they used to work
    it out separately from different parts of the state and disagree. Both now
    read this one answer from the same per-keeper input.

    The answer does not depend on what a request is, so this stays polymorphic
    in it: nothing here can start reading a request's fields and drift again. *)

type 'request t =
  | Sends
  | Queues_behind of 'request

val of_state :
  inflight:'request option -> waiting:'request option -> 'request t
(** [Queues_behind] when a turn for this keeper is in flight, or when a line is
    already waiting for it ([waiting] is the line a new one would join). The
    queue drains when the turn settles and the operator is no longer composing.
    Otherwise Enter sends. *)
