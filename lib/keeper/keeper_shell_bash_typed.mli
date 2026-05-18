val has_typed_bash_input_key : Yojson.Safe.t -> bool

val handle :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  timeout_sec:float ->
  run_in_background:bool ->
  write_enabled:bool ->
  unit ->
  string
