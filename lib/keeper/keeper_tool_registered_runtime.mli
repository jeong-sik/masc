(** Runtime adapter for registered backend tools available to keeper turns. *)

val handle_masc_tool :
  config:Workspace.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_registered_tool :
  config:Workspace.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  string option
