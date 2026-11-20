(** Slot scheduler for LLM requests.

    When capacity is exhausted, requests are queued by their
    {!Admission_class.t} in [Priority > Standard > Background] order. Within a
    class, slots are granted in arrival order.

    Cancel-safe: whether a waiter owns a slot once its wait has ended is
    decided by the waiter's state transition, not by how the wait ended. A
    waiter cancelled, or timed out, after the slot was handed to it in the
    same instant still owns that slot, and uses or returns it; one that was
    never handed a slot leaves the queue. Nothing is leaked either way.

    @since 0.96.0 *)

type t

(** Create a scheduler with [max_slots] concurrent permits.

    With [priority_run_limit = Some limit], a freed slot goes to the oldest
    [Priority] waiter ahead of [Standard]. After [limit] priority grants
    while [Standard] waits, the next foreground grant goes to [Standard].
    Independently, after [limit] foreground ([Priority] or [Standard])
    grants while [Background] waits, the next slot goes to [Background].
    A background grant does not reset the priority grants owed to a waiting
    [Standard] request. Each class keeps arrival order; both lower classes
    receive bounded service while higher classes keep arriving. The bound
    counts permit grants, not elapsed time, and does not preempt holders.

    With [priority_run_limit = None], strict [Priority > Standard > Background]
    ordering applies with zero artificial run-limit default, zero priority
    weights, and zero concurrency cap on [Background] when higher-priority queues
    are empty.

    @raise Invalid_argument if [max_slots < 1] or [limit < 1]. *)
val create : max_slots:int -> priority_run_limit:int option -> t

(** Change the allowance of a scheduler that may have holders and waiters.
    A raised [max_slots] hands the new slots to waiters at once. A lowered
    one takes effect as holders return slots: no slot is handed on while
    more than [max_slots] are held. Every waiter remains in its class queue
    across reconfiguration.

    @raise Invalid_argument if [max_slots < 1] or [limit < 1]. *)
val reconfigure : t -> max_slots:int -> priority_run_limit:int option -> unit

(** How a wait for a slot ended. *)
type wait_end =
  | Wait_granted
  | Wait_expired  (** Only a bounded wait ({!with_permit_until}) expires. *)

(** Run [f] with a permit. If all slots are in use, the request queues as
    [admission_class]. Raises the original exception if [f] fails; the permit is
    still released.

    [on_queue] watches waits: it runs when the request joins the queue, and
    the function it returns runs once when that wait is granted (before [f])
    or, for {!with_permit_until}, expires. A slot granted at once calls
    neither, and a cancelled wait does not call the returned function. Both
    run on the requesting fiber. A raise from either leaves no slot held or
    waiter queued. *)
val with_permit
  :  ?on_queue:(unit -> wait_end -> unit)
  -> admission_class:Admission_class.t
  -> t
  -> (unit -> 'a)
  -> 'a

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
  -> ?on_queue:(unit -> wait_end -> unit)
  -> clock:_ Eio.Time.clock
  -> deadline_at:float
  -> admission_class:Admission_class.t
  -> t
  -> (unit -> 'a)
  -> ('a, [> `Permit_wait_expired ]) result

(** {2 A slot held across calls}

    A caller that decides which of several schedulers to use before it runs
    anything takes the slot first and returns it with {!release} when the
    work is over. *)

(** Take a free slot without waiting. [true] when a slot was under the
    allowance and no request was queued, so a request taken here never
    passes a waiter; [false] queues nothing. *)
val try_acquire : t -> bool

(** Wait for a slot as {!with_permit} does and return once the caller owns
    it. [on_queue] is called as {!with_permit} calls it. A cancelled wait,
    or a raise from [on_queue], leaves no slot held and no waiter queued. *)
val acquire_held
  :  ?on_queue:(unit -> wait_end -> unit)
  -> admission_class:Admission_class.t
  -> t
  -> unit

(** Return a slot taken by {!try_acquire} or {!acquire_held}. A freed slot
    goes to the next waiter as it does when {!with_permit} ends. *)
val release : t -> unit

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

(** Non-blocking point-in-time capacity snapshot. After a lowered
    {!reconfigure}, [active] can exceed [max_slots] until holders return
    slots; [available] is then 0. *)
val snapshot : t -> snapshot
