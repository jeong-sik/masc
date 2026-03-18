(** Heartbeat tools - Agent health monitoring *)

type 'a context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type result = bool * string

val handle_heartbeat : _ context -> Yojson.Safe.t -> result
val handle_heartbeat_start : _ context -> Yojson.Safe.t -> result
val handle_heartbeat_stop : _ context -> Yojson.Safe.t -> result
val handle_heartbeat_list : _ context -> Yojson.Safe.t -> result

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : _ context -> name:string -> args:Yojson.Safe.t -> result option
