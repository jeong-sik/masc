(** Public facade for keeper MCP tools. *)

type 'a context = 'a Keeper_types.context = {
  config : Room.config;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

type tool_result = Keeper_types.tool_result

val schemas : Types.tool_schema list

val dispatch :
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option
