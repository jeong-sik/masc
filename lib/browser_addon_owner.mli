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
val is_retired : t -> bool
(** Admission observation only. It grants neither a new poll nor process cleanup
    authority; an owned resource still waits for its original cleanup request. *)
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
val attach_stagehand : t -> models:bool ->
  execute:(actor:string option -> Browser_lane.verb -> Browser_lane.answer) ->
  session:(unit -> Browser_lane.session_observation) ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Publish an owned Chrome backend independently of automation. Actor identity
    remains attached to its admitted command. Registration does not establish an
    open session. [models] observes the selected consumer/output grant and
    controls model-verb admission independently of native input. Retire fences both backends, starts both
    cleanups and waits for both before answering. Each attached cleanup runs once;
    concurrent or repeated Retire requests observe the same result. An error or
    exception from either cleanup prevents a successful retirement receipt. *)
val attach_live : t -> client_id:Browser_lane.client_id ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Bind cleanup of an already registered exact live BiDi client to this owner.
    Retire revokes its input before joining the original peer and child. Existing
    extension clients grant no browser-process ownership. *)
val revoke : t -> unit
(** First retire admission, then wake pending work and retire the owner's client
    IDs. Interrupted issued work has an unknown outcome and is never replayed. *)

val attach_uploads : t -> Browser_addon_uploads.t -> (unit, string) result
val cleanup_uploads : t -> (unit, string) result
(** After owned backend shutdown, join staging/claims and release pending
    snapshots. Claimed files require the original browser session's teardown. *)
val attach_downloads : t -> Browser_addon_downloads.t -> (unit, string) result
val publish_download : t -> string -> (Yojson.Safe.t, string) result
(** Completed owned download producer. This is independent of LLM consumers. *)
val cleanup_downloads : t -> (unit, string) result
(** Invoke only after confirmed owned backend teardown. Retain unresolved bytes. *)
val dispatch_upload : t -> id:string -> actor:string ->
  route:Browser_lane.route -> verb:Browser_lane.verb -> Browser_addon_wire.reply
(** Mandatory one-use upload admission beneath the optional tool middleware.
    Ordinary private [Issue] refuses upload commands without this grant. *)
