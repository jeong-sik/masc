(** Switch-owned FIFO lanes without policy capacity or timeout.
    Every accepted event is either executed or reported through [on_failure]
    before the owner is released. *)

type lane =
  | Keeper_lane of string
  | Connector_lane of string

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

type t

val lane_to_string : lane -> string
val event_id_to_string : event_id -> string
val failure_reason_to_string : failure_reason -> string
val submit_error_to_string : submit_error -> string

val create :
  sw:Eio.Switch.t ->
  on_failure:(failure -> unit) ->
  unit ->
  t

val submit :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> unit) ->
  (unit, submit_error) result
(** [submit t ...] accepts work only while [t]'s owner switch is available.
    [Error Owner_unavailable] is a terminal rejection: the callback was not
    enqueued. *)
