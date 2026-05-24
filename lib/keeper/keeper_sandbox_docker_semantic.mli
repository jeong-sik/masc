(** Docker sandbox command semantic helpers. *)

val gh_exit_class_field :
  stages:Keeper_shell_command_semantics.parsed_stage list ->
  status:Unix.process_status ->
  output:string ->
  (string * Yojson.Safe.t) list

val docker_command_semantic_status :
  cmd:string -> status:Unix.process_status -> output:string -> Exec_core.semantic_status

val semantic_ok_of_status : Exec_core.semantic_status -> bool
