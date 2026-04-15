val json :
  ?actor:string ->
  ?command_plane_summary:Yojson.Safe.t ->
  ?swarm_status:Yojson.Safe.t ->
  config:Coord.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t

val session_json :
  ?actor:string ->
  ?command_plane_summary:Yojson.Safe.t ->
  ?swarm_status:Yojson.Safe.t ->
  session_id:string ->
  config:Coord.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t
