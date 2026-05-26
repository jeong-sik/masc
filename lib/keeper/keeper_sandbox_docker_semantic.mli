val docker_command_semantic_status
  :  cmd:string
  -> status:Unix.process_status
  -> output:string
  -> Exec_core.semantic_status

val semantic_ok_of_status : Exec_core.semantic_status -> bool
