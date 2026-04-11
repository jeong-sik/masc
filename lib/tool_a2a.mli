(** A2A tools - Agent-to-Agent protocol.
    Only poll_events and heartbeat_result remain active. *)

type context = {
  config: Room.config;
  agent_name: string;
}

type tool_result = bool * string

val handle_poll_events : context -> Yojson.Safe.t -> tool_result
val handle_heartbeat_result : context -> Yojson.Safe.t -> tool_result

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option
