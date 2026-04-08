(** Keeper MASC coordination tool handlers — autoresearch and masc tools. *)

val handle_keeper_autoresearch_tool :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_masc_tool :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
