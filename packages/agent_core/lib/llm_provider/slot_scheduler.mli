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

(** Number of unused slots. *)
val available : t -> int

(** Number of currently active slots. *)
val in_use : t -> int

(** Number of fibers waiting for a slot. *)
val queue_length : t -> int

(** {2 Capacity Query} *)

(** Point-in-time snapshot of scheduler state.
    All counts reflect this OAS process only; other clients sharing the same
    provider server are not visible. *)
type snapshot =
  { max_slots : int
  ; active : int
  ; available : int
  ; queue_length : int
  }

(** Non-blocking point-in-time capacity snapshot. *)
val snapshot : t -> snapshot

(** {2 Non-blocking Acquisition} *)

(** Run [f] if a slot is immediately available and no older request is queued.
    Returns [None] without blocking otherwise. The slot is released when [f]
    returns or raises. *)
val try_with_permit : t -> (unit -> 'a) -> 'a option

(** {2 Explicit Handle API — Turn-Level Slot Yielding}

    Agents can release capacity during tool execution and rejoin the FIFO before
    the next LLM turn.

    Lifecycle: [acquire_permit] -> [yield_permit] -> [resume_permit] ->
    [release_permit]

    @since 0.100.0 *)

(** Opaque handle representing a held or yielded slot permit. *)
type permit

(** Acquire a slot, joining the FIFO if capacity is exhausted. The caller must
    call [release_permit] when done. *)
val acquire_permit : t -> permit

(** Release a held slot temporarily. *)
val yield_permit : t -> permit -> unit

(** Re-acquire a yielded permit through the same FIFO as every other request. *)
val resume_permit : t -> permit -> unit

(** Permanently release a permit. Must be called exactly once per
    [acquire_permit], whether the permit is held or yielded. *)
val release_permit : t -> permit -> unit

(** [true] if the permit currently holds a slot. *)
val permit_is_held : permit -> bool
