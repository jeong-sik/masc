(** Switch-owned FIFO lanes without policy capacity, timeout, or drop paths. *)

type lane =
  | Keeper_lane of string
  | Connector_lane of string

type event_id =
  { source : string
  ; opaque_id : string
  }

type failure =
  { lane : lane
  ; event_id : event_id
  ; reason : string
  }

type t

val lane_to_string : lane -> string
val event_id_to_string : event_id -> string

val create :
  sw:Eio.Switch.t ->
  on_failure:(failure -> unit) ->
  unit ->
  t

val run_isolated :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> 'a) ->
  ('a, failure) result
(** Run a pre-handoff connector operation at its exact event boundary.
    Cancellation propagates. Any other exception is reported through
    [on_failure] and returned as a typed error, so the transport callback can
    continue without weakening durable accept-before-return ordering. *)

val submit :
  t ->
  lane:lane ->
  event_id:event_id ->
  (unit -> unit) ->
  unit
