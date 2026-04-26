val json
  :  ?actor:string
  -> config:Coord.config
  -> sw:Eio.Switch.t
  -> clock:'a Eio.Time.clock
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option
  -> unit
  -> Yojson.Safe.t

val session_json
  :  ?actor:string
  -> session_id:string
  -> config:Coord.config
  -> sw:Eio.Switch.t
  -> clock:'a Eio.Time.clock
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option
  -> unit
  -> Yojson.Safe.t
