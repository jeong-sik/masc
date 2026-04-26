(** Tool_relay — retired hidden relay surface. *)

type context =
  { config : Coord.config
  ; agent_name : string
  ; sw : Eio.Switch.t
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  }

type tool_result = bool * string

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option
val schemas : Types.tool_schema list
