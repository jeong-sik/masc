
(** Worktree tools - Git worktree management for task isolation *)

type context = {
  config: Coord.config;
  agent_name: string;
}

val default_base_branch : string

val handle_worktree_create :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_worktree_remove :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_worktree_list :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.t option

val schemas : Masc_domain.tool_schema list
