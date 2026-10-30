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

type user_image_reference = {
  value : string;  (** The URL or Files-API id, verbatim. *)
  mime_type : string option;  (** Advisory; the chat wire carries it for a reference only on the anthropic source object. *)
}

(** The carrier of a user image: bytes this server already holds (an
    [attachments] entry), or a reference the provider resolves itself — an
    external http(s) URL or a Files-API id minted by an upload tool (#33728).
    The reference forms ride the wire in their native shapes (#33669); this
    server never fetches them. *)
type user_image_source =
  | Attached of user_media_block
  | Url_ref of user_image_reference
  | File_id_ref of user_image_reference

type user_input_block =
  | User_text of string
  | User_image of user_image_source
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
    fields, unknown block types, and malformed media refs are request errors.
    An image block names exactly one carrier — [attachment_id] (bytes),
    [url] (http/https only), or [file_id] — and zero or several at once are
    request errors. Nonblank text blocks retain their original whitespace. *)

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
(** Text fallback for the existing string-only keeper turn path. Nonblank text
    blocks retain their original bytes, joined by paragraph separators.
    Raw media data is never included. *)

(** [Invalid_input]: the blocks or an attachment payload are malformed,
    including base64 that does not decode. [Media_store_unavailable]: the
    payloads were valid and the store could not keep them. *)
type input_error =
  | Invalid_input of string
  | Media_store_unavailable of Agent_core.History.media_error

val input_error_to_string : input_error -> string

val to_agent_core_blocks :
  media_store:Agent_core.History.media_store ->
  attachments:Keeper_chat_store.attachment list ->
  user_input_block list ->
  (Agent_core.Types.content_block list, input_error) result
(** Convert semantic MASC input blocks to AGENT_CORE history blocks.  Media
    blocks resolve their payload through [attachments] by [attachment_id] and
    are put in [media_store]; the block holds the [Stored] reference.
    Data URLs are normalized to raw base64 payloads before they are decoded,
    and declared MIME types must match any MIME embedded in a data URL.
    An image reference crosses as the native carrier form (a [Url] or
    [File_id] source holding the URL or file id) so the serializers emit it
    as-is; nothing is fetched here.

    Dashboard-supported text documents are base64-decoded and validated as
    UTF-8 at this MASC boundary, then projected as AGENT_CORE [Text] blocks so provider
    fallbacks do not need provider-specific file-input support. Binary and
    provider-native documents remain AGENT_CORE [Document] blocks. *)
