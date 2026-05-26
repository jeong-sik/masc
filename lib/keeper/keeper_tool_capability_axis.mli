(** Semantic capability classification for keeper tool names. *)

type t =
  | Claim_task
  | Board_activity
  | Work_discovery
  | Pr_work_action
  | Pr_work_shell_command
  | Pr_work_git_action
  | Docker_route_pr_work_action

val canonical_tool_name : string -> string
val claim_task_tool_names : string list
val board_activity_tool_names : string list
val work_discovery_tool_names : string list
val work_discovery_routing_tool_names : string list
val preferred_work_discovery_tool_names : string list
val pr_work_shell_command_tool_names : string list
val pr_work_git_action_tool_names : string list
val tool_names : t -> string list
val supports : t -> string -> bool
val supports_any : t -> string list -> bool
val shell_command_input_candidates : string -> Yojson.Safe.t -> string list
