(** Portal tools - Agent-to-agent direct messaging *)

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

val filter_visible_tool_names : context -> string list -> string list

val handle_portal_open : context -> Yojson.Safe.t -> result
val handle_portal_send : context -> Yojson.Safe.t -> result
val handle_portal_close : context -> Yojson.Safe.t -> result
val handle_portal_status : context -> Yojson.Safe.t -> result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val schemas : Types.tool_schema list
