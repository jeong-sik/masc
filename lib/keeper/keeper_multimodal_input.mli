(** Keeper_multimodal_input — MASC-side semantic user input blocks.

    This module owns the dashboard/connector input contract before it crosses
    into OAS.  It is intentionally distinct from dashboard rich-render blocks
    and from OAS provider blocks. *)

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

val attachment_to_yojson : Keeper_chat_store.attachment -> Yojson.Safe.t

val attachments_to_yojson : Keeper_chat_store.attachment list -> Yojson.Safe.t

val parse_attachments : Yojson.Safe.t -> Keeper_chat_store.attachment list
(** Parse optional [attachments] from a request/tool argument object.  Malformed
    attachment entries are ignored, matching the historical chat stream
    behavior; referenced-but-missing media is rejected later by {!to_oas_blocks}. *)

val user_blocks_to_yojson : user_input_block list -> Yojson.Safe.t

val parse_user_blocks : Yojson.Safe.t -> (user_input_block list, string) result
(** Parse the optional [user_blocks] request field.  Unknown block types and
    malformed media refs are request errors, not silently ignored. *)

val fallback_message :
  attachments:Keeper_chat_store.attachment list -> user_input_block list -> string
(** Text fallback for the existing string-only keeper turn path.  Raw media data
    is never included. *)

val modalities : user_input_block list -> string list
(** Stable, duplicate-free modality labels present in the input. *)

val to_oas_blocks :
  attachments:Keeper_chat_store.attachment list ->
  user_input_block list ->
  (Agent_sdk.Types.content_block list, string) result
(** Convert semantic MASC input blocks to OAS provider input blocks.  Media
    blocks resolve their payload through [attachments] by [attachment_id].
    Data URLs are normalized to raw base64 payloads before crossing into OAS,
    and declared MIME types must match any MIME embedded in a data URL.

    Dashboard-supported text documents are base64-decoded and validated as
    UTF-8 at this MASC boundary, then projected as OAS [Text] blocks so provider
    fallbacks do not need provider-specific file-input support. Binary and
    provider-native documents remain OAS [Document] blocks. *)
