(** A2A tools - Agent-to-Agent protocol.
    All tool handlers removed (poll_events, heartbeat_result pruned).
    Module retained for dispatch interface compatibility. *)

type context = {
  config: Room.config;
  agent_name: string;
}

type tool_result = bool * string

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option
