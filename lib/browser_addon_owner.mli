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
val attach_models : t -> Browser_addon_models.t -> (unit, string) result
val models_enabled : t -> bool
val model_output : t -> name:string -> Lane_addon_types.exact_output option
val generate : t -> Lane_addon_exact.request ->
  (Browser_addon_models.outcome, Browser_addon_models.error) result
(** An original browser command owns the waiting scope. Cancellation withdraws
    its model request. Never hold the admission lock while waiting. *)
val attach_automation : t -> locate:bool -> execute:(Browser_lane.verb -> Browser_lane.answer) ->
  session:(unit -> Browser_lane.session_observation) ->
  document:(tab_id:int -> Browser_lane.answer) ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Publish a ready worker-owned backend. Revocation removes all three callbacks
    before resource teardown. A retired owner cannot acquire a backend. *)
val attach_stagehand : t ->
  execute:(actor:string option -> Browser_lane.verb -> Browser_lane.answer) ->
  session:(unit -> Browser_lane.session_observation) ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Publish an owned Chrome backend independently of automation. Actor identity
    remains attached to its admitted command. Registration does not establish an
    open session or model availability. Retire fences both backends, starts both
    cleanups and waits for both before answering. Each attached cleanup runs once;
    concurrent or repeated Retire requests observe the same result. An error or
    exception from either cleanup prevents a successful retirement receipt. *)
val revoke : t -> unit
(** First retire admission, then wake pending work and retire the owner's client
    IDs. Interrupted issued work has an unknown outcome and is never replayed. *)
