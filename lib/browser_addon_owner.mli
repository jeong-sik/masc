(** One browser worker owns the process-local lane registry for its whole life.
    A retired owner cannot be reopened; replacement requires a fresh process. *)
type t
val create : incarnation:string -> (t, string) result
(** The incarnation is a canonical UUID supplied by the host. At most one owner
    may be created in a process. Creation installs live-lane activity only;
    owned browser backends remain unavailable until their cleanup is attached. *)
val dispatch : t -> Browser_addon_wire.request -> Browser_addon_wire.reply
(** Concurrent requests are allowed. Admission is serialized only while binding
    clients/targets, never while waiting for browser input or a poll result. *)
val snapshot : t -> Yojson.Safe.t
val incarnation : t -> string
val attach_automation : t -> execute:(Browser_lane.verb -> Browser_lane.answer) ->
  session:(unit -> Browser_lane.session_observation) ->
  document:(tab_id:int -> Browser_lane.answer) ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Publish a ready worker-owned backend. Revocation removes all three callbacks
    before resource teardown. A retired owner cannot acquire a backend. *)
val revoke : t -> unit
(** First retire admission, then wake pending work and retire the owner's client
    IDs. Interrupted issued work has an unknown outcome and is never replayed. *)
