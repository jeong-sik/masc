(** Runtime adapter for client-intercepted voice agent tools.

    The [voice_command] type is the canonical closed enumeration of
    supported subcommands. [command_to_string] is the SSOT mapping;
    [command_of_string] is derived from it and [all_commands], so that
    new variants only require adding an entry in two places (the type
    + the [command_to_string] match), both compiler-checked. *)

type voice_command =
  | Speak
  | Listen
  | Agent
  | Sessions
  | Session_start
  | Session_end

val all_commands : voice_command list

val command_to_string : voice_command -> string

val command_of_string : string -> voice_command option

val handle_voice_tool :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  unit ->
  string

val handle_voice_tool_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t
