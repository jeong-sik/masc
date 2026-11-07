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
val mark_ego_user_owned_name : t -> space:string -> ids:int list -> observed_at:float -> (unit, string) result
(** Publish an observed startup conflict only while this owner serves. *)
val mark_ego_space_missing : t -> space:string -> space_id:int -> observed_at:float -> (unit, string) result
(** Publish that ego no longer lists the Space a connection was bound to,
    only while this owner serves and nothing else is published. *)
val clear_ego_unavailable : t -> unit
(** The published ego refusal ended: the Space was claimed or the lane serves again. *)
(** What a recovery did: claimed the user-owned Space back, or cleared a
    missing Space's record and started opening the configured name again;
    the connection follows on its own either way. *)
type ego_recovered = Reclaimed of {space_id:int; space_name:string} | Reopening of {space:string}
val attach_ego_recovery : t ->
  (Browser_addon_observation.unavailable -> (ego_recovered, string) result) -> (unit, string) result
(** The live ego backend's recovery: it receives the one published record
    and answers with what it did. One recovery runs at a time; a second
    while one runs is refused before the SDK is asked anything. *)
val detach_ego_recovery : t -> unit
(** Admission observation only. It grants neither a new poll nor process cleanup
    authority; an owned resource still waits for its original cleanup request. *)
type ego_space = {
  space_observation : unit -> Browser_ego_space_observation.t option;
  space_presence : unit -> Browser_ego_space_observation.presence;
}
(** The ego connection's dated Space reads, published with its client row. *)
val attach_live : ?ego_space:ego_space -> t -> client_id:Browser_lane.client_id ->
  cleanup:(unit -> (unit, string) result) -> (unit, string) result
(** Bind cleanup of an already registered exact live client this worker runs,
    a BiDi or an ego connection, one of each at most. Retire revokes its input
    before joining its connection: the original BiDi peer and child, or the ego
    task space. Existing extension clients grant no browser-process ownership.
    Once attached, the lane holds the client instead of timing its polls; it
    ends only through [disconnect_live] or [revoke]. *)
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
    end. Each is a wire command, made inside the worker. *)
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
