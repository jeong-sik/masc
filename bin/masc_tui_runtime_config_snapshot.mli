(** Pure projections of one immutable server-owned source reading. No UI,
    request ownership, palette, Runtime parser or environment is read here. *)
type rows = (string * string) list list

type t = private {
  reading : Masc_tui_runtime_config_view.reading;
  rows : rows;
  models : (Masc_tui_model_runtime_table.row list, string) result;
}

val source_rows : path:string -> string -> rows
(** Shared, palette-independent whole-source lexer and terminal sanitization. *)

val of_reading : Masc_tui_runtime_config_view.reading -> t
(** Source text/metadata and server model projection retain the same reading.
    Missing, unavailable or mismatched model/group evidence remains an error
    without hiding the original source. No local source reparse fallback. *)

val rows_for_source : path:string -> source_text:string -> t -> rows option
(** [None] means path or full source text differs. [Some rows] reuses the
    immutable projection; this grants no read, revision or mutation authority. *)
