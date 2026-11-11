(** Domain_mailbox — operations sent from any domain, taken in order by one
    fiber, with an end both sides agree on.

    One fiber {!serve}s the mailbox. Any fiber of any domain {!send}s to it,
    without waiting. Operations are handled in the order they were sent.

    The mailbox ends once: when the handler says [`Finished], or when the
    serving fiber is cancelled or raises. From then on {!send} answers
    [false] and queues nothing. An operation was either handled, or given to
    [unhandled] by {!serve}, or refused by {!send}: exactly one of the three,
    so a sender that waits for an answer to its operation always gets one.

    RFC http-transport-runs-on-its-own-domain §3.3: the handler of a request
    runs on the main domain and its response operations cross to the fiber of
    the connection through one of these. *)

type 'op t

val create : unit -> 'op t

val send : 'op t -> 'op -> bool
(** Queues [op] and returns [true], or returns [false] when the mailbox has
    ended. Never waits: the queue has no bound. Safe from any domain. *)

val serve
  :  'op t
  -> handle:('op -> [ `Continue | `Finished ])
  -> unhandled:('op -> unit)
  -> unit
(** Takes operations in order and gives each to [handle], until it answers
    [`Finished]. Then, or when this fiber is cancelled or [handle] raises,
    the mailbox ends and every operation still queued goes to [unhandled], in
    order. An operation [handle] raised on goes to [unhandled] first.
    [unhandled] runs on this fiber, shielded from cancellation, and must not
    raise. Call once per mailbox. *)
