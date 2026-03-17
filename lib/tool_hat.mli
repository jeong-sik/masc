(** Hat tools - Agent role management *)

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

val handle_hat_wear : context -> Yojson.Safe.t -> result
val handle_hat_status : context -> Yojson.Safe.t -> result

val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
