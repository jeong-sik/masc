(** Semantic capability classification for keeper tool names. *)

type t =
  | Claim_task
  | Board_activity
  | Shell_command_input
  | Polling_read

val canonical_tool_name : string -> string
val claim_task_tool_names : string list
val board_activity_tool_names : string list
val shell_command_input_tool_names : string list
val polling_read_tool_names : string list
val tool_names : t -> string list
val supports : t -> string -> bool
val supports_any : t -> string list -> bool
val shell_command_input_candidates : string -> Yojson.Safe.t -> string list
