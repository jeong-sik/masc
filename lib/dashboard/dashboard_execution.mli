val json :
  ?actor:string ->
  ?fixture:string ->
  ?light:bool ->
  config:Coord.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t
