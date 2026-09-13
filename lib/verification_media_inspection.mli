(** Complete captured media inspection shared by verifier Read and the operator
    CLI. This runs document parsers/renderers or video decoders; no model judges
    the result and no Task or Goal lifecycle is changed. *)
type kind = Pdf | Presentation | Video
val detect : path:string -> bytes:string -> kind option
(** [None] means this is not one of the supported document/video formats. *)
val whole_file_label : kind -> string
val inspect : kind -> base_path:string -> name:string -> path:string ->
  bytes:string -> start_time:float -> max_image_bytes:int -> Tool_result.result
(** Returns [Completed] with original source identity and exact inspection scope,
    including rendered image content for PDF/PPTX, or the inspector's typed
    [Failed] result. Does not return [Deferred]. Private captures are removed
    at the end of inspection. The supplied complete source bytes are immutable. *)
