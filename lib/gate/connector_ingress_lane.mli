(** Switch-owned FIFO lanes with optional bounded per-lane capacity.
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
    (** Explicit positive capacity bound per lane queue. *)
  }

type bounded_submit_error =
  | Closed
  | Lane_full of
      { lane : lane
      ; pending : int
      ; capacity : int
      }

type t

val lane_to_string : lane -> string
val event_id_to_string : event_id -> string
val failure_reason_to_string : failure_reason -> string
val submit_error_to_string : submit_error -> string
val bounded_submit_error_to_string : bounded_submit_error -> string

val create :
  sw:Eio.Switch.t ->
  ?config:lane_config ->
  on_failure:(failure -> unit) ->
  unit ->
  t
(** Create switch-owned ingress lanes. When [?config] is supplied,
    [config.max_pending_per_lane] must be strictly positive (otherwise raises
    [Invalid_argument]). *)

val create_bounded :
  sw:Eio.Switch.t ->
  config:lane_config ->
  on_failure:(failure -> unit) ->
  unit ->
  t
(** Same as {!create} with a required declared {!lane_config}. *)

val submit :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> unit) ->
  (unit, submit_error) result
(** [submit t ...] accepts work only while [t]'s owner switch is available and
    capacity permits. [Error Owner_unavailable] is returned on rejection. Callers
    that distinguish capacity backpressure from owner shutdown should use
    {!submit_bounded}. *)

val submit_bounded :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> unit) ->
  (unit, bounded_submit_error) result
(** Bounded submission returning [Error (Lane_full _)] when the lane's queue
    has reached [config.max_pending_per_lane], or [Error Closed] when the owner
    switch is unavailable. *)

val pending_count : t -> lane:lane -> int
(** Current queued (not yet started) jobs on [lane]. *)

val capacity : t -> int option
(** Declared per-lane capacity bound, or [None] when created without [?config]. *)
