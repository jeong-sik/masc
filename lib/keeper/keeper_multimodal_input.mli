(** Keeper_multimodal_input — MASC-side semantic user input blocks.

    This module owns the dashboard/connector input contract before it crosses
    into AGENT_CORE.  It is intentionally distinct from dashboard rich-render blocks
    and from AGENT_CORE provider blocks. *)

type user_media_block = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int option;
}

type user_input_block =
  | User_text of string
  | User_image of user_media_block
  | User_document of user_media_block
  | User_audio of user_media_block

val attachments_to_yojson : Keeper_chat_store.attachment list -> Yojson.Safe.t

val parse_attachments :
  Yojson.Safe.t -> (Keeper_chat_store.attachment list, string) result
(** Parse optional [attachments] from a request object. Duplicate or undeclared
    fields, wrong types, missing [id]/[data], and a duplicated [id] are request
    errors.  A duplicate id would parse twice while a user_blocks reference
    reaches only the first entry, silently shadowing the other. *)

val user_blocks_to_yojson : user_input_block list -> Yojson.Safe.t

val parse_user_blocks : Yojson.Safe.t -> (user_input_block list, string) result
(** Parse the optional [user_blocks] request field. Duplicate or undeclared
    fields, unknown block types, and malformed media refs are request errors. *)

val validate_attachment_references :
  attachments:Keeper_chat_store.attachment list ->
  user_input_block list ->
  (unit, string) result
(** Fail closed when an [attachments] entry is not referenced by any
    [user_blocks] media block.  Attachments are a byte store; an unreferenced
    attachment never reaches AGENT_CORE and would otherwise be silently
    dropped.  Referencing the same attachment more than once is allowed. *)

val fallback_message :
  attachments:Keeper_chat_store.attachment list -> user_input_block list -> string
(** Text fallback for the existing string-only keeper turn path.  Raw media data
    is never included. *)

val modalities : user_input_block list -> string list
(** Stable, duplicate-free modality labels present in the input. *)

val to_agent_core_blocks :
  attachments:Keeper_chat_store.attachment list ->
  user_input_block list ->
  (Agent_core.Types.content_block list, string) result
(** Convert semantic MASC input blocks to AGENT_CORE provider input blocks.  Media
    blocks resolve their payload through [attachments] by [attachment_id].
    Data URLs are normalized to raw base64 payloads before crossing into AGENT_CORE,
    and declared MIME types must match any MIME embedded in a data URL.

    Dashboard-supported text documents are base64-decoded and validated as
    UTF-8 at this MASC boundary, then projected as AGENT_CORE [Text] blocks so provider
    fallbacks do not need provider-specific file-input support. Binary and
    provider-native documents remain AGENT_CORE [Document] blocks. *)
