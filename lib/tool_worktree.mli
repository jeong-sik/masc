
(** Worktree tools - Git worktree management for task isolation *)

type context = {
  config: Coord.config;
  agent_name: string;
}

type tool_result = bool * string

val default_base_branch : string

val handle_worktree_create : context -> Yojson.Safe.t -> tool_result
val handle_worktree_remove : context -> Yojson.Safe.t -> tool_result
val handle_worktree_list : context -> Yojson.Safe.t -> tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val schemas : Masc_domain.tool_schema list
