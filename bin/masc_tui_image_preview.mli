(** Ctrl-O chooses the newest image in the current conversation or composer.
    Sent attachments retain a typed content address; filenames are labels,
    never local paths. *)
type order = Named_is_newer | Staged_is_newer | Unordered

type output_source = private
  | Inline_data of string
  | Inline_svg of string
  | Server_path of string
  | Remote_uri of string

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | Stored_attachment of { name : string; reference : Tool_output.artifact_ref }
  | Output_image of { name : string; source : output_source }
  | Unavailable_image of { name : string; reason : string }
  | No_image

val persisted_attachment : name:string -> mime:string -> data:string option -> preview
(** Only a validated durable blob marker is readable. Image metadata without
    retained bytes is explicitly unavailable. Non-images produce [No_image]. *)

val output_image : name:string -> src:string -> preview
(** Parse a producer-declared image source once: inline data, a path on the
    authenticated peer, an HTTP URI, or an explicit unavailable source. *)

val inline_svg : name:string -> string -> preview
(** SVG markup supplied by the canonical SVG block, never a local path. *)

val in_message : text:string -> attachments:preview list -> preview
(** The last image attachment, otherwise the last path in the original text.
    Attachment display labels must never be included in [text]. *)

val choose_preview : conversation:preview -> staged:Masc_tui_keeper_chat_projection.attachment list -> order:order -> preview

val decode_payload : string -> (string, string) result
(** Decode a retained wire payload (bare base64 or a base64 data URI). *)

val decode_artifact : Tool_output.artifact_ref -> Yojson.Safe.t -> (string, string) result
(** Verify the response identity, retained wire byte count, and content digest
    against the recorded reference before decoding the image payload. *)
