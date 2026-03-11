(** Public facade for keeper MCP tools. *)

type 'a context = 'a Keeper_types.context = {
  config : Room.config;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

type tool_result = Keeper_types.tool_result
type keeper_meta = Keeper_types.keeper_meta
type keeper_reward_model = Keeper_memory.keeper_reward_model

val schemas : Types.tool_schema list

val validate_name : string -> bool

val resident_keeper_names : Room.config -> string list
val persistent_agent_names : Room.config -> string list

val read_meta : Room.config -> string -> (keeper_meta option, string) result
val write_meta : Room.config -> keeper_meta -> (unit, string) result

val active_model_of_meta : keeper_meta -> string
val parse_agent_status : Room.config -> agent_name:string -> Yojson.Safe.t
val load_keeper_reward_model : string -> (keeper_reward_model, string) result
val autonomous_gate_config :
  autonomy_level:Keeper_autonomy.autonomy_level -> Eval_gate.gate_config

val dispatch :
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option
