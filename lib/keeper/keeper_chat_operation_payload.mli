(** Strict durable payload for one Keeper chat operation. *)

type person_caller =
  { user_id : Authz_types.User_id.t
  ; stored_scope : Authz_types.Authorization_scope.t
  }

val equal_person_caller : person_caller option -> person_caller option -> bool

(** Verify live PAT / owner / keeper / runtime admission via
    {!Runtime_account_access.admit_by_engine_name} and capture the resulting
    [stored_scope] into a {!person_caller} for queue persistence. *)
val admit_person_caller
  :  engine_name:string
  -> user_id:Authz_types.User_id.t
  -> channel:Authz_types.Channel.t
  -> pat:Authz_types.Pat_binding.t
  -> (person_caller, Runtime_account_access.refusal) result

type connector_attachment = Discord_image of { attachment_id : string }

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
  ; connector_attachments : connector_attachment list
  ; extra_mentions : Keeper_identity.Keeper_id.t list
  ; sender_keeper : Keeper_identity.Keeper_id.t option
      (** The registered Keeper that sent this operation, decided where the
          operation was submitted by an exact Keeper registry match on the
          submitter. [None] for the operator and for connector speakers.
          Written as ["sender_keeper"] (string or null); the field is
          required on read. *)
  ; user_row_origin : Keeper_chat_store.user_row_origin
  ; person_caller : person_caller option
      (** Authenticated human caller and [stored_scope] captured at admission
          time for multi-account person Keeper turns (RFC §6.4). Written as
          ["person_caller"] (object or null); the field is required on read. *)
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

val source_to_json_with_person_caller :
  person_caller:person_caller option ->
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

val with_connector_attachments :
  source:Yojson.Safe.t -> connector_attachment list -> (Yojson.Safe.t, string) result
(** Retain attachment IDs on a Discord source matching its original message.
    Sources without attachments retain their existing wire version. *)

val source_of_json : Yojson.Safe.t -> (decoded_source, string) result
val input_of_json : Yojson.Safe.t -> (decoded_input, string) result
