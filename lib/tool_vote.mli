(** Vote tools - Consensus voting system *)

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

val handle_vote_create : context -> Yojson.Safe.t -> result
val handle_vote_cast : context -> Yojson.Safe.t -> result
val handle_vote_status : context -> Yojson.Safe.t -> result
val handle_votes : context -> Yojson.Safe.t -> result

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
