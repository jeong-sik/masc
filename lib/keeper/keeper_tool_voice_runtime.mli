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

(** Caller-owned authorization boundary around one concrete voice effect. The
    voice runtime invokes it only at the TTS/playback or microphone/STT leaf;
    local capability and session reads do not become Gate requests. *)
type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> Keeper_tool_execution.t) ->
  Keeper_tool_execution.t

val handle_voice_tool :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  authorize_external_effect:external_effect_authorizer ->
  name:string ->
  args:Yojson.Safe.t ->
  unit ->
  string

val handle_voice_tool_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  authorize_external_effect:external_effect_authorizer ->
  name:string ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t
