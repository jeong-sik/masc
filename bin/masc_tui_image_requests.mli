(** Chat image acquisition outside the render loop. The caller captures the
    endpoint and later checks its request generation before displaying bytes. *)
type source =
  | Retained of Tool_output.artifact_ref
  | Generated of Masc_tui_image_preview.output_source

val load :
  host:string -> port:int -> cache_dir:(unit -> string) -> source ->
  (string, string) result
(** Fetch the authenticated peer in an Eio fiber. Run retained-payload
    verification, base64 decoding, remote downloads and image conversion on a
    system thread. Returns PNG bytes or the acquisition/decoder refusal. *)
