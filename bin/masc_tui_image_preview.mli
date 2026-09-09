(** Ctrl-O chooses the newest image in the current conversation or composer.
    Sent attachments retain a typed content address; filenames are labels,
    never local paths. *)
type order = Named_is_newer | Staged_is_newer | Unordered

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | Stored_attachment of { name : string; reference : Tool_output.artifact_ref }
  | Unavailable_attachment of string
  | No_image

val persisted_attachment : name:string -> mime:string -> data:string option -> preview
(** Only a validated durable blob marker is readable. Image metadata without
    retained bytes is explicitly unavailable. Non-images produce [No_image]. *)

val in_message : text:string -> attachments:preview list -> preview
(** The last image attachment, otherwise the last path in the original text.
    Attachment display labels must never be included in [text]. *)

val choose_preview : conversation:preview -> staged:Masc_tui_keeper_chat_projection.attachment list -> order:order -> preview

val decode_payload : string -> (string, string) result
(** Decode a retained wire payload (bare base64 or a base64 data URI). *)
