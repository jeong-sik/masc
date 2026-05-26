(* Keeper_workspace_read_ops — structured read-side SearchFiles operations. *)

val try_handle :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  op:string ->
  raw_path:string ->
  string option
