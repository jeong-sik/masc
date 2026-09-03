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
}
(** One column at one row: what it is called, how many cells it may occupy, how
    it sits in them, and what this row puts there. Private so a cell cannot be
    assembled without a header and a width -- the pairing is the point. *)

val cell : ?align:align -> header:string -> width:int -> string -> cell
(** [cell ~header ~width value] describes one column carrying [value].
    [align] defaults to {!Left}; numbers usually want {!Right}. *)

val used_width : gap:int -> cell list -> int
(** Cells the row occupies, the [gap] between columns included. *)

val header_row : gap:int -> cell list -> string
(** The column names, laid out on the given cells. *)

val row : gap:int -> cell list -> string
(** One row's readings, laid out on the same cells as {!header_row}. A reading
    past its width folds in the middle; it never widens its column, so a row is
    exactly as wide as the header above it whatever it carries. *)
