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
    voice runtime invokes it only at the TTS/playback leaf; the microphone
    window is wall-clock bound, so listening stays ungated, and local
    capability and session reads do not become Gate requests either.
    [call_summary] is the speak's declared one-line statement
    ({!speak_call_summary}); the authorizer forwards it to the Gate request
    without reading it. *)
type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  call_summary:string option ->
  continue:(unit -> Keeper_tool_execution.t) ->
  Keeper_tool_execution.t

val speak_message_of_args : Yojson.Safe.t -> (string, string) result
(** The one argument a speak is for, read once for the handler and for the
    approval row: [message], trimmed. Absent, non-string, or blank is an
    error; the handler refuses such a call and the replay engine states no
    summary for it. *)

val speak_call_summary : message:string -> string option
(** The one line a speak approval is about: the first non-blank line of the
    message, whole. This is the speak tool's declared call summary; the
    handler states it when it asks the Gate, and the replay engine states it
    from {!speak_message_of_args} over the approved input. *)

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
