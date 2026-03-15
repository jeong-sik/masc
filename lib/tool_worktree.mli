(** Worktree tools - Git worktree management for task isolation *)

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

val handle_worktree_create : context -> Yojson.Safe.t -> result
val handle_worktree_remove : context -> Yojson.Safe.t -> result
val handle_worktree_list : context -> Yojson.Safe.t -> result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val schemas : Types.tool_schema list
