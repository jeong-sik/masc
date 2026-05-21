(** Keeper MASC coordination tool handlers. *)

val handle_keeper_masc_tool :
  config:Coord.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_registered_keeper_tool :
  config:Coord.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string option
