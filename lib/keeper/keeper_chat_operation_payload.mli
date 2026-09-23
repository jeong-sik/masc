(** Strict durable payload for one Keeper chat operation. *)

type decoded_source =
  { submitted_by : string
  ; thread_id : string
  ; continuation_channel : Keeper_continuation_channel.t
  ; surface : Surface_ref.t
  ; channel : string
  ; channel_user_id : string
  ; channel_user_name : string
  ; channel_workspace_id : string
  ; conversation_id : string option
  ; external_message_id : string option
  ; workspace_id : string option
  ; extra_mentions : Keeper_identity.Keeper_id.t list
  ; sender_keeper : Keeper_identity.Keeper_id.t option
      (** The registered Keeper that sent this operation, decided where the
          operation was submitted by an exact Keeper registry match on the
          submitter. [None] for the operator and for connector speakers.
          Written as ["sender_keeper"] (string or null); the field is
          required on read (RFC-0468 §3.2). *)
  ; user_row_origin : Keeper_chat_store.user_row_origin
  }

type decoded_input =
  { message : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; turn_instructions : string option
  ; surface_context : Yojson.Safe.t option
  ; attachments : Keeper_chat_store.attachment list
  }

val source_to_json :
  submitted_by:string ->
  thread_id:string ->
  continuation_channel:Keeper_continuation_channel.t ->
  surface:Surface_ref.t ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  conversation_id:string option ->
  external_message_id:string option ->
  workspace_id:string option ->
  extra_mentions:Keeper_identity.Keeper_id.t list ->
  sender_keeper:Keeper_identity.Keeper_id.t option ->
  user_row_origin:Keeper_chat_store.user_row_origin ->
  (Yojson.Safe.t, string) result

val input_to_json :
  message:string ->
  user_blocks:Keeper_multimodal_input.user_input_block list ->
  turn_instructions:string option ->
  surface_context:Yojson.Safe.t option ->
  attachments:Keeper_chat_store.attachment list ->
  Yojson.Safe.t

val source_of_json : Yojson.Safe.t -> (decoded_source, string) result
val input_of_json : Yojson.Safe.t -> (decoded_input, string) result
