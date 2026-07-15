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

(** Forks the idle dispatcher as a daemon fiber on [sw]: the switch can
    finish once its non-daemon fibers are done, after draining any in-flight
    lane jobs (which run as regular fibers). *)
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
  unit
