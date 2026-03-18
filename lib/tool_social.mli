(** Tool_social - MCP tool handlers for social features *)

type context = {
  config: Room_utils.config;
  agent_name: string;
}

type result = bool * string

val handle_post_create : context -> Yojson.Safe.t -> result
val handle_post_list : context -> Yojson.Safe.t -> result
val handle_post_get : context -> Yojson.Safe.t -> result
val handle_comment_add : context -> Yojson.Safe.t -> result
val handle_comment_list : context -> Yojson.Safe.t -> result
val handle_vote : context -> Yojson.Safe.t -> result

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
