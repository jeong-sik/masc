(** Fair FIFO slot scheduler for LLM requests.

    Capacity is the only scheduling constraint. When capacity is exhausted,
    requests are queued and granted slots in arrival order.

    Cancel-safe: whether a waiter owns a slot once its wait has ended is
    decided by the waiter's state transition, not by how the wait ended. A
    waiter cancelled, or timed out, after the slot was handed to it in the
    same instant still owns that slot, and uses or returns it; one that was
    never handed a slot leaves the queue. Nothing is leaked either way.

    @since 0.96.0 *)

type t

(** Create a scheduler with [max_slots] concurrent permits.
    @raise Invalid_argument if [max_slots < 1]. *)
val create : max_slots:int -> t

(** Run [f] with a permit. If all slots are in use, the request joins the FIFO.
    Raises the original exception if [f] fails; the permit is still released. *)
val with_permit : t -> (unit -> 'a) -> 'a

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
    bounds is over, and the slot is the caller's. [f] runs without this
    deadline; the caller bounds it. *)
val with_permit_until
  :  ?wait:permit_wait Atomic.t
  -> clock:_ Eio.Time.clock
  -> deadline_at:float
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
