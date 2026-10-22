(** One terminal palette and table-frame preference shared by chat and documents. *)
val table_frame_enabled : bool ref
val palette : closing:string -> Masc_tui_markdown.palette
val render : closing:string -> width:int -> string -> string list
val document : width:int -> string -> string list
val fenced : language:string -> string -> string
