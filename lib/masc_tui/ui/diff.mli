(** Line-oriented diff calculation, numbered-gutter windowing, and direct
    {!Masc_tui_term.Cell_grid.t} syntax-highlighted unified diff rendering. *)

module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid

type row =
  | Context of string
  | Removed of string
  | Added of string

type numbered = {
  nrow : row;
  old_line : int option;
  new_line : int option;
}

val equal_row : row -> row -> bool
val equal_numbered : numbered -> numbered -> bool

val rows : before:string -> after:string -> row list
(** Compute common prefix, removed/added middle, and common suffix without
    inventing a spurious empty line for trailing newlines. *)

val counts : row list -> int * int
(** [(removed_count, added_count)]. *)

val preview : context:int -> max_rows:int -> row list -> row list * int
(** Keep at most [context] unchanged lines around the changed middle within
    [max_rows], returning [(shown_rows, omitted_count)]. *)

val number : old_start:int -> new_start:int option -> row list -> numbered list
(** Attach old/new file line coordinates to each diff row. *)

val preview_numbered :
  context:int -> max_rows:int -> numbered list -> numbered list * int

val line_number_cell : int option -> string
(** Five-cell coordinate string (["    -"] for absent lines). *)

val numbered_gutter_cells : int
(** [14]: two five-cell coordinate columns, diff marker, and separating spaces. *)

val numbered_gutter :
  old_line:int option -> new_line:int option -> marker:char -> string

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?language:Code_lexer.language ->
  ?scroll:int ->
  numbered list ->
  int
(** Paint numbered diff rows onto [Cell_grid.t] with colored markers and
    optional syntax highlighting via {!Code_lexer}. Returns total row count. *)
