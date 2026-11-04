val scope_of_request_target :
  string -> (Workspace_dataset_event.browser_scope option, string) result
(** Read the optional browser target of an observer stream. *)

val request_json : Workspace_dataset_event.browser_scope -> Yojson.Safe.t
(** The existing canonical read request for this exact target. *)

type watcher

val watch : Workspace_dataset_event.browser_scope -> watcher

val observe :
  watcher -> Yojson.Safe.t ->
  (Workspace_dataset_event.browser_observation option, string) result
(** Announce only a changed observation of the watcher's own target. Capture
    duration does not count as a content change; payload bytes never enter
    the returned observation. *)

val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> stop_promise:unit Eio.Promise.t ->
  scope:Workspace_dataset_event.browser_scope -> config:Workspace.config -> unit
(** Sample only the selected target while its observer stream is open. *)

module For_testing : sig
  val with_reader :
    (config:Workspace.config -> Workspace_dataset_event.browser_scope ->
     (Yojson.Safe.t, string) result) ->
    (unit -> 'a) -> 'a
end
