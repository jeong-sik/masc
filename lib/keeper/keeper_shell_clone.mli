(** Git clone / pull handler for keeper sandbox ops. *)

val handle :
  op:string ->
  meta:Keeper_types.keeper_meta ->
  config:Coord.config ->
  args:Yojson.Safe.t ->
  string
