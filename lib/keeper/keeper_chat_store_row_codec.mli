(** The JSON line of one chat row: writing a row, the ids it gets, and reading
    its lifecycle fields back.

    [encode_line] writes a row as one JSON line. A row that comes without a
    [message_id] gets one from [mint_message_id], which joins the timestamp in
    microseconds to a counter ([message_id_counter]) that counts up in this
    process.
    [validate_row_fields] returns [Error] naming the first field of a stored
    row that the store does not know.
    [parse_stream_lifecycle] and [parse_approval_lifecycle] read the
    [stream_lifecycle] and [approval_lifecycle] fields of a stored row. A
    value that does not decode is reported through
    [report_persistence_read_drop] and read as [None].
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val parse_stream_lifecycle :
  path:string ->
  Yojson.Safe.t ->
  stream_lifecycle_event list option

val parse_approval_lifecycle :
  path:string ->
  Yojson.Safe.t ->
  approval_lifecycle option

val mint_message_id : ts:float -> string

val validate_row_fields : (string * 'a) list -> (unit, string) result

val encode_line :
  role:Role.t ->
  content:string ->
  ts:float ->
  ?message_id:string ->
  ?attachments:attachment list ->
  ?tool_call_id:string ->
  ?execution_id:Ids.Execution_id.t ->
  ?tool_call_name:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?workspace_id:string ->
  ?speaker:speaker ->
  ?audio:audio_clip ->
  ?blocks:chat_block list ->
  ?mentions:Keeper_identity.Keeper_id.t list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  ?approval_lifecycle:approval_lifecycle ->
  ?provenance:Keeper_chat_delivery_identity.delivery_provenance ->
  unit -> string
