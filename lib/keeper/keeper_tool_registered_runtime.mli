(** Runtime adapter for registered backend tools available to keeper turns. *)

val handle_masc_tool_with_outcome :
  config:Workspace.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

val handle_registered_tool_with_outcome :
  config:Workspace.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t option
