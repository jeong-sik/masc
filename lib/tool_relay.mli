(** Relay tools - Infinite context via handoff (all tools orphaned) *)

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

val dispatch : context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

val schemas : Types.tool_schema list
