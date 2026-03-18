(** A2A tools - Agent-to-Agent protocol *)

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

val handle_a2a_discover : context -> Yojson.Safe.t -> result
val handle_a2a_query_skill : context -> Yojson.Safe.t -> result
val handle_a2a_delegate : context -> Yojson.Safe.t -> result
val handle_a2a_subscribe : context -> Yojson.Safe.t -> result
val handle_a2a_unsubscribe : context -> Yojson.Safe.t -> result
val handle_poll_events : context -> Yojson.Safe.t -> result

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
