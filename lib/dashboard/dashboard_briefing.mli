type observation = Dashboard_projection_read.observation = {
  json : Yojson.Safe.t;
  next_deadline_unix : float option;
  completeness : Dashboard_projection_read.completeness;
}

val observe_current :
  ?actor:string ->
  config:Workspace.config -> sw:Eio.Switch.t -> clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option -> unit -> observation
(** Bypass actor snapshot/digest and nested operator metadata TTLs. The
    returned deadline belongs to the same source observation: source-dated
    agent truth, selected tool-host failure attention and active judgment.
    Typed Keeper roster/row and digest storage failures retain the readable
    rows with [Partial] completeness, and so does a digest that could not be
    read. The caller owns timeout/failure retry.
    This API alone does not start or
    remove a server worker. *)

val json :
  ?actor:string ->
  config:Workspace.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t
(** The briefing through the actor snapshot and digest caches. Both reads
    publish [digest_read] ([read], [timed_out] or [unreadable]) and
    [digest_read_error], the diagnostic of an unreadable digest. A digest that
    was not read publishes [incidents], [recommended_actions],
    [attention_queue] and [internal_signals] as [null], not as empty lists,
    and names the workspace health [unknown]. *)
