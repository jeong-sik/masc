(** Auth tools - Authentication and authorization *)

type context = {
  config: Room.config;
  agent_name: string;
}

type tool_result = bool * string

val handle_auth_enable : context -> Yojson.Safe.t -> tool_result
val handle_auth_disable : context -> Yojson.Safe.t -> tool_result
val handle_auth_status : context -> Yojson.Safe.t -> tool_result
val handle_auth_create_token : context -> Yojson.Safe.t -> tool_result
val handle_auth_refresh : context -> Yojson.Safe.t -> tool_result
val handle_auth_revoke : context -> Yojson.Safe.t -> tool_result
val handle_auth_list : context -> Yojson.Safe.t -> tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val schemas : Types.tool_schema list
