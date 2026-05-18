val workflow_rejection_field : string * Yojson.Safe.t

val bash_shape_block_result :
  cmd:string ->
  cmd_for_log:string ->
  env_snapshot:Yojson.Safe.t option ->
  Keeper_shell_bash_shape_messages.bash_shape_block ->
  string

val task_state_http_probe_block : cmd:string -> cmd_for_log:string -> unit -> string
val task_state_file_probe_block : cmd:string -> cmd_for_log:string -> unit -> string
