val is_pdf : string -> string -> bool
val is_mp4 : string -> string -> bool
val is_presentation : string -> bool

val video_result :
  base_path:string -> name:string -> path:string -> bytes:string ->
  start_time:float -> Tool_result.result

val pdf_result :
  base_path:string -> name:string -> path:string -> bytes:string ->
  start_time:float -> max_image_bytes:int -> Tool_result.result

val presentation_result :
  base_path:string -> name:string -> path:string -> bytes:string ->
  start_time:float -> max_image_bytes:int -> Tool_result.result

(** Result construction shared by verifier Read and operator inspection.
    Callers retain their own authorization and bounded source-read policies. *)
