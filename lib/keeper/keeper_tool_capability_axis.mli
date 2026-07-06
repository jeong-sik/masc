(** Semantic capability classification for keeper tool names. *)

type t =
  | Claim_task
  | Board_activity
  | Shell_command_input
  | Polling_read

type command_candidate_error =
  | Tool_execute_input_parse_error of string

val command_candidate_error_to_string : command_candidate_error -> string
val command_candidate_error_label : command_candidate_error -> string

val canonical_tool_name : string -> string
val claim_task_tool_names : string list
val board_activity_tool_names : string list
val shell_command_input_tool_names : string list
(** Descriptor-projected read-only tools that poll an existing async request. *)
val polling_read_tool_names : string list
val tool_names : t -> string list
val supports : t -> string -> bool
val supports_any : t -> string list -> bool
val shell_command_input_candidates_result :
  string -> Yojson.Safe.t -> (string list, command_candidate_error) result

val shell_command_input_candidates : string -> Yojson.Safe.t -> string list
