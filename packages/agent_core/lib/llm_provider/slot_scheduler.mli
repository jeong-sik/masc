(** Fair FIFO slot scheduler for LLM requests.

    Capacity is the only scheduling constraint. When capacity is exhausted,
    requests are queued and granted slots in arrival order.

    Cancel-safe: if a waiting fiber is cancelled, the slot is not leaked.

    @since 0.96.0 *)

type t

(** Create a scheduler with [max_slots] concurrent permits.
    @raise Invalid_argument if [max_slots < 1]. *)
val create : max_slots:int -> t

(** Run [f] with a permit. If all slots are in use, the request joins the FIFO.
    Raises the original exception if [f] fails; the permit is still released. *)
val with_permit : t -> (unit -> 'a) -> 'a

(** [with_permit] whose wait for a slot ends at [deadline_at] on [clock]:
    [Error `Permit_wait_expired] when no slot was granted by then (the waiter
    leaves the queue), [Ok (f ())] otherwise. [f] runs without this deadline;
    the caller bounds it. *)
val with_permit_until
  :  clock:_ Eio.Time.clock
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
