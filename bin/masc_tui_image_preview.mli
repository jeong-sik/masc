(** Ctrl-O chooses the newest image or diagram in the conversation or composer.
    Sent attachments retain a typed content address; filenames are labels,
    never local paths. *)
type order = Named_is_newer | Staged_is_newer | Unordered

type output_source = private
  | Inline_data of string
  | Inline_svg of string
  | Inline_mermaid of string
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

val mermaid : name:string -> string -> preview
(** Exact source for the offline Pele renderer. No parsing or process work. *)

val mermaid_source : string -> output_source
(** The bare source for callers that build an image request source directly.
    The type stays private; match on it, do not rebuild it. *)

val in_message : text:string -> attachments:preview list -> preview
(** The last image attachment, otherwise the last closed Mermaid fence, then
    the last path in the original text.
    Attachment display labels must never be included in [text]. *)

val in_message_previews : text:string -> attachments:preview list -> preview list
(** All named images, closed Mermaid fences and supplied image attachments,
    oldest first within each group. The last item preserves {!in_message}'s
    precedence. A Mermaid source also present as a supplied structured output
    appears only once, with that output's caption. Does not read or decode bytes. *)

val newest : preview list -> preview
(** Last non-[No_image] item, or [No_image]. *)

val newest_first : conversation:preview list -> staged:Masc_tui_keeper_chat_projection.attachment list -> order:order -> preview list
(** Frozen selection catalog. Uses the same staged/conversation precedence as
    {!choose_preview}, retaining every source within each group. *)

val prioritize_sources : newly_observed:('a -> bool) -> ('a * preview list) list -> ('a * preview list) list * order
(** Preserve source occurrences while moving current arrivals after older
    sources. A newly observed source with no preview cannot supersede staging.
    The caller supplies original source identity/arrival ownership, never time. *)

val choose_preview : conversation:preview -> staged:Masc_tui_keeper_chat_projection.attachment list -> order:order -> preview

val decode_payload : string -> (string, string) result
(** Decode a retained wire payload (bare base64 or a base64 data URI). *)

val decode_artifact : Tool_output.artifact_ref -> Yojson.Safe.t -> (string, string) result
(** Verify the response identity, retained wire byte count, and content digest
    against the recorded reference before decoding the image payload. *)
