(** Runtime path rewrites for tool execute responses and Docker commands. *)

val replace_all_substrings :
  needle:string -> replacement:string -> string -> string

val rewrite_turn_runtime_paths_to_host :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string

val rewrite_docker_host_paths_to_container :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string
