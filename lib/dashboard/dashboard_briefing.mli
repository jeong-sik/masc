type observation = { json : Yojson.Safe.t; next_deadline_unix : float option }

val observe_current :
  ?actor:string ->
  config:Workspace.config -> sw:Eio.Switch.t -> clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option -> unit -> observation
(** Bypass actor snapshot/digest and nested operator metadata TTLs. The
    returned deadline belongs to the same source observation: source-dated
    agent truth, selected tool-host failure attention and active judgment.
    The caller owns timeout/failure retry. This API alone does not start or
    remove a server worker. *)

val json :
  ?actor:string ->
  config:Workspace.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t
