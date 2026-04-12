(** Relay tools - Infinite context via handoff *)

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type tool_result = bool * string

val handle_relay_status : context -> Yojson.Safe.t -> tool_result
val handle_relay_checkpoint : context -> Yojson.Safe.t -> tool_result
val handle_relay_now : context -> Yojson.Safe.t -> tool_result
val handle_relay_smart_check : context -> Yojson.Safe.t -> tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val schemas : Types.tool_schema list
