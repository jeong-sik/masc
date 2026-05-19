val existing_dir_path_values : string -> string list

val validate_command_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  string ->
  (unit, string) result
