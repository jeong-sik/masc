(** The rows the help overlay draws, and the height it draws them in.

    The overlay folds its lines into two columns once the terminal is wide
    enough, so what it draws is fewer rows than it was written as. The key
    handler bounded the scroll with the line count and no height at all, and
    the drawing clamped the result on the way past -- the shape
    {!Masc_tui_scroll} was written to end. On a wide terminal the sheet
    stopped at its last row while the state counted on to twice that, so
    scrolling back up paid off the surplus one press at a time before the
    reader saw anything move.

    Both sides ask this module now, so they answer with the same number. *)

val line_cells : cols:int -> int
(** The cells one sheet line has at this width: the frame's inner width while
    the sheet is one column, a column's width once it is two. Lines wider than
    this are cut where they are drawn, so the lines are wrapped to it first. *)

val sheet : ?header:string list -> cols:int -> string list -> string list
(** The rows drawn at this width: optional full-width header rows, followed by
    the lines as written, or -- once a terminal is wide enough to hold two
    columns -- the sections between blank lines set side by side two at a
    time, each whole, with a blank row between pairs. *)

