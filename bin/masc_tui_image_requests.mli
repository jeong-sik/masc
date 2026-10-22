(** Chat image acquisition outside the render loop. The caller captures the
    endpoint and later checks its request generation before displaying bytes. *)
type source =
  | Local_file of string
  | Draft of Masc_tui_keeper_chat_projection.attachment
  | Retained of { reference : Tool_output.artifact_ref;
      format : Masc_tui_image_payload.format }
  | Generated of Masc_tui_image_preview.output_source

val load :
  host:string -> port:int -> cache_dir:(unit -> string) ->
  diagram_width:int -> diagram_colors:(string * string) option ->
  display:Masc_tui_image_cache.display -> source ->
  (Masc_tui_image_cache.presentation, string) result
(** [Local_file] reads its selected path and [Draft] decodes its captured
    local payload, without peer identity or HTTP. Other sources keep
    authenticated-peer ownership.
    Fetch the authenticated peer in an Eio fiber. Run retained-payload
    verification, base64 decoding, remote downloads and image conversion on a
    system thread. Prepare the captured pixel or character-cell presentation
    there as well; the caller owns all terminal writes and stale-result checks. *)
(* Declared SVG uses the offline renderer after decoding. A retained format
   comes from the original attachment metadata, distinct from its base64 wire
   blob's MIME. Byte count and digest verification precede rendering. *)
