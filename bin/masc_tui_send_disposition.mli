(** What pressing Enter in the Keeper chat composer does.

    The send path and the footer both need this answer, and they used to work
    it out separately from different parts of the state. They disagreed: a
    request being reconciled or cleaned up has no durable fence standing, so
    Enter held the line for the next turn while the footer said
    [Enter:blocked]. The operator saw "queued 1" and "blocked" on screen at
    the same time.

    The answer does not depend on what a request is, so this stays polymorphic
    in it: nothing here can start reading a request's fields and drift again. *)

type 'request t =
  | Sends
  | Queues_behind of 'request
  | Refused_prepared of 'request
  | Refused_cleanup of 'request
  | Refused_recovery_blocked of string
  | Refused_unverified of 'request

val of_state :
  prepared:'request option ->
  cleanup_pending:'request option ->
  recovery_blocked:string option ->
  inflight:'request option ->
  unverified:'request option ->
  'request t
(** The order is the contract. A durable fence outranks a running turn because
    it says no further POST is authorized; a running turn outranks an
    unverified outcome because the turn is being watched and the queue drains
    when it settles. *)
