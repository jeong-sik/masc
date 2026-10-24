val is_image : string -> bool
(** Classify a declared MIME media type; no filename or content guessing. *)

val is_markdown : string -> bool
(** Markdown media types shared by document reading and diagram selection. *)

val images :
  mime_type:string option -> Masc_tui_mcp.resource_content list ->
  (int * Masc_tui_image_preview.preview) list
(** Original one-based content-part numbers and image candidates in response
    order. Markdown text parts expose closed Mermaid fences with their exact
    source for the offline Pele renderer. HTML text parts expose inert embedded base64 images, parsed inline
    SVG roots, and explicit
    unavailability for external/unsupported images. Several images can belong
    to the same original part. Does not decode bytes, read paths, fetch URIs
    or run converters. *)

val same_reading :
  equal:('key -> 'key -> bool) ->
  ('key * Masc_tui_mcp.resource_content list) option ->
  ('key * Masc_tui_mcp.resource_content list) option -> bool
(** The same URI and physically retained immutable content list. Equal newly
    read bytes are a different observation; absence never owns a preview. *)
