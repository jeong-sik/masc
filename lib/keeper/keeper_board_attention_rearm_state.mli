(** Immutable state for one contention key. Before each transition the worker
    locates the exact key under its mutex. It owns the scheduler-wide ticket
    counter and every callback; ticket IDs continue across entry resets. *)

type ticket = private
  { ticket_id : int
  ; delay_s : float
  }

type phase = Idle | Pending of ticket | Inflight of ticket
type t

val initial : t
val phase : t -> phase
(** [Idle] retains the next delay; removing the entry is what resets history. *)

type reservation =
  { state : t
  ; ticket : ticket
  ; next_ticket_id : int
  }
(** Publish [state] and [next_ticket_id] together under the worker's mutex,
    before launching [ticket]. Reset must never rewind the scheduler counter. *)

type schedule =
  | Scheduled of reservation
  | Already_pending of ticket
  | Already_inflight of ticket

val schedule : next_ticket_id:int -> t -> schedule

val begin_delivery : t -> ticket -> t option
(** [Some] moves the matching Pending ticket to Inflight. [None] means that
    this callback no longer owns a pending reservation. *)

val cancel_pending : t -> ticket -> t option
(** Clear only a matching Pending ticket, retaining delay history. [None]
    means no change; in particular an Inflight request is not cancelled. *)

type 'a completion =
  | Delivered of t * 'a
  | Retry of reservation
  | Suppressed

val complete_delivery :
  next_ticket_id:int -> t -> ticket -> ('a, 'error) result -> 'a completion
(** Use the current entry re-read after the outside-lock request. Every [Ok]
    releases the matching Inflight ticket to Idle; only a returned [Error]
    reserves a retry. [Suppressed] leaves a replaced or stale ticket alone.
    A raised request has no completion transition. *)
