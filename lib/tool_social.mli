(** Tool_social - MCP tool handlers for social features *)

val get_string : Yojson.Safe.t -> string -> string -> string
val get_string_opt : Yojson.Safe.t -> string -> string option
val get_int : Yojson.Safe.t -> string -> int -> int

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

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
