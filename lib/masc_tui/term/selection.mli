(** App-internal mouse text selection over a {!Cell_grid.t}.

    The terminal's native drag-select is the default (mouse capture OFF).
    When the operator enables mouse capture with bare [m], the app owns
    drag events and this module:
    - paints only the dragged cells, trimmed per row to the last
      non-blank cell so a partial drag never bleeds full-width,
    - extracts the dragged text (rows joined by [\n], trailing blanks
      trimmed, leading blanks kept) for [Cmd.Copy_clipboard].

    Extraction reads the presented front grid, so it covers exactly what
    the operator sees, including wide (CJK) grapheme clusters. *)

open Masc_tui_core

val is_blank_cell : Cell_grid.cell -> bool
(** [true] iff the cell carries no glyph ([Empty], or Braille mask [0]). *)

val extract_text : Cell_grid.t -> rect:Rect.t -> string
(** Concatenate cell glyphs row by row, joining rows with [\n].
    Trailing blank cells of each row are dropped and trailing blank
    rows are omitted, so a selection over trailing margins copies
    trimmed text. Returns [""] when [rect] holds no glyph. *)

val paint :
  Cell_grid.t ->
  rect:Rect.t ->
  fg:Color.t ->
  bg:Color.t ->
  unit
(** Overwrite every non-blank cell in [rect], up to each row's last
    non-blank cell, with [fg]/[bg] (preserving the original attributes).
    Blank rows inside [rect] are left untouched. Wide-glyph
    continuation halves are included so no half glyph is left behind. *)
