(** Runtime adapter for registered backend tools available to keeper turns.

    [handle_masc_tool_with_outcome] is gone from this interface: its only
    callers were this module's own fallthrough arms, and exporting it invited
    a second dispatch of effects the entry point had already run. *)

val handle_registered_tool_with_outcome :
  config:Workspace.config ->
  keeper_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t option
