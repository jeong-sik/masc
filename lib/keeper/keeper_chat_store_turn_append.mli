(** The writers that append the rows of one turn.

    [append_turn_result] appends one completed turn as consecutive lines: the
    user row, one row per tool call and the assistant row. [append_turn] is
    the same and ignores the result. [append_user_and_tool_calls_result]
    appends the user row and the tool rows of a turn that reached no assistant
    terminal, and [append_tool_calls_result] appends tool rows alone.
    [append_assistant_message_result] appends one assistant row that has no
    user turn to pair with.
    [user_line_mentions] derives the mentions of a user line from the content
    that is stored and adds the [extra_mentions] that a connector supplies.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val user_line_mentions :
  extra_mentions:Keeper_identity.Keeper_id.t list ->
  string -> Keeper_identity.Keeper_id.t list

val append_turn :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  ?tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  assistant_content:string ->
  unit ->
  unit

val append_user_and_tool_calls_result :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  ?turn_ref:Ids.Turn_ref.t ->
  unit ->
  (unit, string) result

val append_tool_calls_result :
  base_dir:string ->
  keeper_name:string ->
  tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?turn_ref:Ids.Turn_ref.t ->
  unit ->
  (unit, string) result

val append_assistant_message_result :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?audio:audio_clip ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  (unit, string) result
