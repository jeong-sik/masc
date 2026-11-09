(** A reading page drawn from [Masc_tui_page_line] lines. A fact's label sits
    receded in a column as wide as the page's longest label, so the values start
    at one cell; a title is bold, a quiet line is receded, an info line is drawn
    in the info colour and an attention line is warned. A value with a word wider than the room beside its label (a hash,
    a path), or on a screen too narrow to leave it room, goes on the rows under
    the label, so no word is cut at a column in the middle. A list is its label
    receded on a row of its own and a numbered row for each value under it, so a
    value that wraps stays under its own number.

    Every row is a pair of the style it is drawn in and its text; a fact's text
    carries the escapes for its receded label and its value, and its pair holds
    the reset style. *)

val detail_indent : string
(** The cells every row of a detail block is indented by. *)

val wrap_indented_line :
  max_cells:int -> string -> string -> (string * string) list
(** [wrap_indented_line ~max_cells style text] folds [text] at [max_cells] cells
    and indents each row, pairing it with [style]. Blank text is one blank row. *)

val wrap_indented_lines :
  max_cells:int -> string -> string list -> (string * string) list
(** [wrap_indented_line] for each of the lines, in order. *)

val tone_style : Masc_tui_page_line.tone -> string
(** The style a tone is drawn in. *)

val widest_label_cells : Masc_tui_page_line.t list -> int
(** The label column of a page: its longest label with the colon after it, among
    the labels that fit the cap. A label wider than the column goes on a row of
    its own with its value under it, so one long label does not widen the column
    of every other row. A page drawn as several blocks under their own headings
    passes the widest of its blocks to [rows], so the values of every block
    start at one cell. *)

val rows :
  ?label_cells:int ->
  max_cells:int ->
  Masc_tui_page_line.t list ->
  (string * string) list
(** [rows ~max_cells lines] draws the page. [label_cells] defaults to
    [widest_label_cells lines]. *)
