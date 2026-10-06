(** Slot scheduler for LLM requests.

    When capacity is exhausted, requests are queued by their
    {!Admission_class.t}. Within a class, slots are granted in arrival order.
    A scheduler created without a priority run limit has a single queue, so
    every request is granted in arrival order whatever its class.

    Cancel-safe: whether a waiter owns a slot once its wait has ended is
    decided by the waiter's state transition, not by how the wait ended. A
    waiter cancelled, or timed out, after the slot was handed to it in the
    same instant still owns that slot, and uses or returns it; one that was
    never handed a slot leaves the queue. Nothing is leaked either way.

    @since 0.96.0 *)

type t

(** Create a scheduler with [max_slots] concurrent permits.

    With [priority_run_limit = Some limit], a freed slot goes to the oldest
    [Priority] waiter. Once [Priority] has taken [limit] slots in a row while
    a [Standard] waiter was queued, the next slot goes to the oldest
    [Standard] waiter, so [Standard] gets at least one slot in every
    [limit + 1] while both classes wait. With [None] there is one queue.

    @raise Invalid_argument if [max_slots < 1] or [limit < 1]. *)
val create : max_slots:int -> priority_run_limit:int option -> t

(** Run [f] with a permit. If all slots are in use, the request joins the
    queue of [admission_class]. Raises the original exception if [f] fails;
    the permit is still released. *)
val with_permit : admission_class:Admission_class.t -> t -> (unit -> 'a) -> 'a

(** A bounded wait for a slot as its caller sees it. The caller owns the
    cell and starts it at [Before_any_wait]; the wait writes
    [Waiting_for_permit] as it begins and [Wait_settled_at now] as it ends,
    however it ends (granted, expired, cancelled), [now] read on the wait's
    clock. A slot granted at once is no wait and writes nothing. Only a
    bounded wait writes, so a caller that stands its own watchdog down while
    [Waiting_for_permit] never does so for a wait nothing else ends, and
    [Wait_settled_at] is the instant that watchdog counts from again. A
    write is an [Atomic.set]: it cannot raise or block, so the cell cannot
    cost the wait its slot or its place in the queue. *)
type permit_wait =
  | Before_any_wait
  | Waiting_for_permit
  | Wait_settled_at of float

(** [with_permit] whose wait for a slot ends at [deadline_at] on [clock]:
    [Error `Permit_wait_expired] when no slot was granted by then (the waiter
    leaves the queue), [Ok (f ())] otherwise, including when the slot was
    granted in the same instant the deadline passed: the wait this deadline
    bounds is over, and the slot is the caller's. A deadline already passed
    asks for no slot. [f] runs without this deadline; the caller bounds
    it. *)
val with_permit_until
  :  ?wait:permit_wait Atomic.t
  -> clock:_ Eio.Time.clock
  -> deadline_at:float
  -> admission_class:Admission_class.t
  -> t
  -> (unit -> 'a)
  -> ('a, [> `Permit_wait_expired ]) result

(** {2 Capacity Query} *)

(** Point-in-time snapshot of scheduler state.
    All counts reflect this AGENT_CORE process only; other clients sharing the same
    provider server are not visible. *)
type snapshot =
  { max_slots : int
  ; active : int
  ; available : int
  ; queue_length : int
  }

(** Non-blocking point-in-time capacity snapshot. *)
val snapshot : t -> snapshot
