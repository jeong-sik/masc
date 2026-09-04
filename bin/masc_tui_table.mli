(** Column layout for a plain-text table.

    A screen describes its columns once and draws both its header and its rows
    from that description, so the two cannot place a column differently. This
    replaces a pair of format strings per screen, where the widths were written
    twice and printf's width was a floor: a reading longer than its field was
    printed whole and pushed every cell after it out of its column. *)

type align =
  | Left
  | Right

type cell = private {
  header : string;
  width : int;
  align : align;
  value : string;
  style : string;
}
(** One column at one row: what it is called, how many cells it may occupy, how
    it sits in them, and what this row puts there. Private so a cell cannot be
    assembled without a header and a width -- the pairing is the point. *)

val cell :
  ?align:align -> ?style:string -> header:string -> width:int -> string -> cell
(** [cell ~header ~width value] describes one column carrying [value].
    [align] defaults to {!Left}; numbers usually want {!Right}.

    [style] dresses this cell's reading and nothing else -- an ANSI prefix the
    caller owns, closed after the cell. It is how one deviating reading is
    coloured without colouring the row: a keeper that is late says so in its
    state cell and in the reading that measures how late, while the rest of
    the row stays the colour the caller gave the line. Column names never take
    it; a header is not a reading. *)

val cell_gap : int
(** Cells between one column and the next, the same on every table on every
    screen. Exported for a table whose last column has no widest form and is
    appended after the cells rather than laid out as one: it spaces that
    column the way the contract spaces the rest.

    It was each table's own number. Nine of the ten chose one and the Memory
    table chose two, recording no reason, so moving between two screens moved
    the columns under the reader's eye. There is nothing to pass now. *)

val used_width : cell list -> int
(** Cells the row occupies, the gaps between columns included. *)

val header_row : cell list -> string
(** The column names, laid out on the given cells. *)

val row : ?close:string -> cell list -> string
(** One row's readings, laid out on the same cells as {!header_row}. A reading
    past its width folds in the middle; it never widens its column, so a row is
    exactly as wide as the header above it whatever it carries -- styled cells
    included, since the escapes occupy no display cells.

    [close] ends a styled cell and defaults to a plain reset. Pass the line's
    own dress when the row sits inside one, or the cells after a coloured one
    come out undressed. *)
