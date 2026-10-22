val is_image : string -> bool
(** Classify a declared MIME media type; no filename or content guessing. *)

val images :
  mime_type:string option -> Masc_tui_mcp.resource_content list ->
  (int * Masc_tui_image_preview.preview) list
(** Original one-based content-part numbers and inline sources, in response
    order. Does not decode bytes, read paths, fetch URIs or run converters. *)

val same_reading :
  equal:('key -> 'key -> bool) ->
  ('key * Masc_tui_mcp.resource_content list) option ->
  ('key * Masc_tui_mcp.resource_content list) option -> bool
(** The same URI and physically retained immutable content list. Equal newly
    read bytes are a different observation; absence never owns a preview. *)
