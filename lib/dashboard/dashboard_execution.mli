val json :
  ?actor:string ->
  ?fixture:string ->
  ?digest_json:Yojson.Safe.t ->
  ?command_plane_summary:Yojson.Safe.t ->
  ?swarm_status:Yojson.Safe.t ->
  ?light:bool ->
  config:Room.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t
