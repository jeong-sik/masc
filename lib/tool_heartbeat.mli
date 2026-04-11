(** Heartbeat tools - Agent health monitoring *)

type 'a context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type tool_result = bool * string

val handle_heartbeat : _ context -> Yojson.Safe.t -> tool_result
val handle_heartbeat_start : _ context -> Yojson.Safe.t -> tool_result
val handle_heartbeat_stop : _ context -> Yojson.Safe.t -> tool_result
val handle_heartbeat_list : _ context -> Yojson.Safe.t -> tool_result

(** Canonical masc_heartbeat schema — SSOT.
    Other modules derive their projections from this value. *)
val heartbeat_schema : Types.tool_schema

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : _ context -> name:string -> args:Yojson.Safe.t -> tool_result option
