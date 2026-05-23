val render_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  ?cwd:string ->
  cmd:string ->
  string list ->
  string

val render_completed_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  ?cwd:string ->
  cmd:string ->
  ?extra:(string * Yojson.Safe.t) list ->
  Unix.process_status ->
  string ->
  string

val render_docker_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  docker_cmd:string ->
  timeout_sec:float ->
  string
