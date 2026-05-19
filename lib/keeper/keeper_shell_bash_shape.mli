type safe_read_fallback = {
  primary_cmd : string;
  cwd_override : string option;
}

val raw_keeper_bash_shape_block :
  string -> Keeper_shell_bash_shape_messages.bash_shape_block option

val keeper_bash_shape_block :
  string -> Keeper_shell_bash_shape_messages.bash_shape_block option

val safe_read_fallback_of_command :
  write_enabled:bool ->
  stderr_dev_null_stripped:bool ->
  string ->
  safe_read_fallback option

val shape_block_allowed_by_active_validator :
  write_enabled:bool ->
  string ->
  Keeper_shell_bash_shape_messages.bash_shape_block ->
  bool
