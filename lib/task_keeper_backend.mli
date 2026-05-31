(** Keeper-aware task helpers behind the task-tool boundary. *)

val is_registered_agent_alias : Coord.config -> string -> bool
val sync_current_task_binding : Coord.config -> agent_name:string -> unit
val agent_tool_names : Coord.config -> agent_name:string -> string list option
val transition_action_denylist : Coord.config -> agent_name:string -> string list
val active_goal_phases_for_agent : Coord.config -> agent_name:string -> string list
