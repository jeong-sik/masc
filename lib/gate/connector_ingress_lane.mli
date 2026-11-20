(** Switch-owned FIFO lanes with optional cooperative per-lane backpressure.
    Every accepted event is either executed or reported through [on_failure]
    before the owner is released. *)

type lane = Keeper_lane of string

type event_id =
  { source : string
  ; opaque_id : string
  }

type failure_reason =
  | Callback_raised of string
  | Callback_cancelled of string
  | Owner_released

type failure =
  { lane : lane
  ; event_id : event_id
  ; reason : failure_reason
  }

type submit_error = Owner_unavailable

type lane_config =
  { max_pending_per_lane : int
    (** Explicit positive queued-depth threshold per lane at which {!submit}
        applies cooperative Eio backpressure until an in-flight item drains. *)
  }

type t

val lane_to_string : lane -> string
val event_id_to_string : event_id -> string
val failure_reason_to_string : failure_reason -> string
val submit_error_to_string : submit_error -> string

val create :
  sw:Eio.Switch.t ->
  ?config:lane_config ->
  on_failure:(failure -> unit) ->
  unit ->
  t
(** Create switch-owned ingress lanes. When [?config] is supplied,
    [config.max_pending_per_lane] must be strictly positive (otherwise raises
    [Invalid_argument]). *)

val submit :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> unit) ->
  (unit, submit_error) result
(** [submit t ~lane ~event_id run] enqueues [run] onto [lane]'s FIFO queue
    while [t]'s owner switch is available.

    When [t] was created with [?config] and [lane] currently has at least
    [config.max_pending_per_lane] queued items (or earlier waiters ahead of
    this caller), [submit] cooperatively suspends the calling fiber via
    [Eio.Condition] in FIFO arrival order until a queued slot drains, or
    returns [Error Owner_unavailable] if the owner switch closes or fails
    while waiting.

    Propagates [Eio.Cancel.Cancelled] if the calling fiber is cancelled while
    waiting. *)

val pending_count : t -> lane:lane -> int
(** Current queued (not yet started) jobs on [lane]. *)

val capacity : t -> int option
(** Declared per-lane backpressure depth, or [None] when created without
    [?config]. *)
