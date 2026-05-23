val gh_exit_class_field :
  stages:Keeper_shell_command_semantics.parsed_stage list ->
  status:Unix.process_status ->
  output:string ->
  (string * Yojson.Safe.t) list

val docker_command_semantic_status :
  cmd:string -> status:Unix.process_status -> output:string -> Exec_core.semantic_status

val docker_command_semantic_success :
  cmd:string -> status:Unix.process_status -> output:string -> bool
