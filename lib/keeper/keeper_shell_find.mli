(** Find files by pattern in keeper read-target scope. *)

val handle :
  op:string ->
  meta:Keeper_types.keeper_meta ->
  config:Coord.config ->
  args:Yojson.Safe.t ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  root:string ->
  raw_path:string ->
  string
