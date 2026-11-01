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
val mark_ego_user_owned_name : t -> space:string -> observed_at:float -> (unit, string) result
(** Publish an observed startup conflict only while this owner serves. *)
(** Admission observation only. It grants neither a new poll nor process cleanup
    authority; an owned resource still waits for its original cleanup request. *)
val attach_models : t -> Browser_addon_models.t -> (unit, string) result
val models_enabled : t -> bool
val model_output : t -> name:string -> Lane_addon_types.exact_output option
val locate_system : t -> (string, string) result
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
val attach_extensions : t ->
  (Browser_extension_protocol.command ->
    (Yojson.Safe.t, Browser_extension_protocol.error) result) -> (unit, string) result
(** One private executor attached to the already owned Chrome backend. Admission
    is revoked before cleanup. The admission lock is never held during execution. *)
val attach_live : ?ego_input:Browser_ego_operator.recovery -> t -> client_id:Browser_lane.client_id ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Bind cleanup of an already registered exact live client this worker runs,
    a BiDi or an ego connection, one of each at most. Retire revokes its input
    before joining its connection: the original BiDi peer and child, or the ego
    task space. Existing extension clients grant no browser-process ownership.
    Once attached, the lane holds the client instead of timing its polls; it
    ends only through [disconnect_live] or [revoke]. *)
val operator_schema : Yojson.Safe.t
val operator : t -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Private [lane_operator] port, never exported to models. Its host caller
    must use the existing operator-credential/incarnation boundary. Only the
    original connected Ego peer's exact pending generation can be asserted. *)
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
(** A live connection this worker runs: its next command, or [None] once the
    window passed or the owner retired; its result for one command; and its
    end. Each is the request a native host sends, made inside the worker. *)
val poll_live : t -> client:Browser_lane.client_info -> window_sec:float ->
  (Browser_lane.issued option, string) result
val live_request_window : t -> client_id:Browser_lane.client_id -> id:string ->
  Browser_lane.live_request_window
(** Read the original local issuer's remaining window and interruption
    signal, which resolves on local cancellation or client disconnection.
    Normal reply timeout does not resolve that signal; socket EOF in
    another process does not by itself prove local caller cancellation. A
    missing waiter or retired owner cannot authorize a browser effect. *)
val deliver_live : t -> client_id:Browser_lane.client_id -> id:string -> payload:Yojson.Safe.t ->
  (unit, string) result
val disconnect_live : t -> Browser_lane.client_id -> unit
val dispatch_upload : t -> id:string -> actor:string ->
  route:Browser_lane.route -> verb:Browser_lane.verb -> Browser_addon_wire.reply
(** Mandatory one-use upload admission beneath the optional tool middleware.
    Ordinary private [Issue] refuses upload commands without this grant. *)
