(** Runtime adapter for descriptor-backed Remote_mcp agent tools. *)

val handle_masc_tool :
  config:Coord.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_registered_remote_tool :
  config:Coord.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string option
