(** Chat image acquisition outside the render loop. The caller captures the
    endpoint and later checks its request generation before displaying bytes. *)
type source =
  | Retained of { reference : Tool_output.artifact_ref;
      format : Masc_tui_image_payload.format }
  | Generated of Masc_tui_image_preview.output_source

val load :
  host:string -> port:int -> cache_dir:(unit -> string) ->
  diagram_width:int -> diagram_colors:(string * string) option -> source ->
  (string, string) result
(** Fetch the authenticated peer in an Eio fiber. Run retained-payload
    verification, base64 decoding, remote downloads and image conversion on a
    system thread. Returns PNG bytes or the acquisition/decoder refusal. *)
(* Declared SVG uses the offline renderer after decoding. A retained format
   comes from the original attachment metadata, distinct from its base64 wire
   blob's MIME. Byte count and digest verification precede rendering. *)
