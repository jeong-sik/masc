(** Worktree tools - Git worktree management for task isolation *)

type context = {
  config: Coord.config;
  agent_name: string;
}

type tool_result = bool * string

val handle_worktree_create : context -> Yojson.Safe.t -> tool_result
val handle_worktree_remove : context -> Yojson.Safe.t -> tool_result
val handle_worktree_list : context -> Yojson.Safe.t -> tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val schemas : Types.tool_schema list
