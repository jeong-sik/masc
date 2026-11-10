(** The JSON array of messages, and the transcript of one turn.

    [to_json_array] renders messages as a JSON array through
    [Keeper_chat_projection.message_to_json]. It looks up the trace block of a
    message by its turn ([trace_block_for_turn]) and sets [expired] on the
    audio clip of a message. Internal input-binding rows remain stored and
    readable for idempotency, but are omitted from this presentation array.
    Physical page cursors belong to the caller and are not recalculated here.
    A [turn_transcript] holds the user rows and the assistant rows of one turn;
    [transcript_of_messages] and [turn_transcript_to_json] are those of
    [Keeper_chat_projection].
    [load_turn_transcript_result] reads the transcript of a turn page by page.
    A row must pass [exact_transcript_row_identity] and decode strictly, or the
    read is an [Error]. It scans the pages twice, from the same first page: once
    for the rows of the turn and once for the user rows that belong to it.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val to_json_array :
  ?base_dir:string ->
  ?trace_block_by_turn_ref:(Ids.Turn_ref.t -> chat_block option) ->
  ?omit_stream_contract:bool ->
  chat_message list ->
  Yojson.Safe.t

type turn_transcript = Keeper_chat_projection.turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

val transcript_of_messages :
  chat_message list -> turn_ref:Ids.Turn_ref.t -> turn_transcript

val turn_transcript_to_json :
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  turn_transcript ->
  Yojson.Safe.t

val load_turn_transcript_result :
  base_dir:string ->
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  (turn_transcript, Keeper_chat_history_page.error) result
