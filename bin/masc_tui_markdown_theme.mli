(** One terminal palette and table-frame preference shared by chat and documents. *)
val table_frame_enabled : bool ref
val palette : closing:string -> Masc_tui_markdown.palette

type dress
(** The opening codes the reader's settings give the chat's Markdown, read
    once. *)

val dress : unit -> dress
(** Read the settings. Call it on the UI domain, which owns them. *)

val palette_of : dress -> closing:string -> Masc_tui_markdown.palette
(** The palette from codes already read; it reads no setting. *)
val render : closing:string -> width:int -> string -> string list
val document : width:int -> string -> string list
val code : language:string -> width:int -> string -> string list
(** Render already terminal-safe source as highlighted, hard-wrapped code.
    Unlike a Markdown fence, source lines cannot close this block. *)
val fenced : language:string -> string -> string
