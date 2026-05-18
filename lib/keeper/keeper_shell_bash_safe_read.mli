type t = {
  primary_cmd : string;
}

val of_command :
  shape_block_of_command:(string -> 'block option) ->
  write_enabled:bool ->
  stderr_dev_null_stripped:bool ->
  string ->
  t option
