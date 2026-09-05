(** The rows the help overlay draws, and the height it draws them in.

    The overlay folds its lines into two columns once the terminal is wide
    enough, so what it draws is half of what it was written as. The key
    handler bounded the scroll with the line count and no height at all, and
    the drawing clamped the result on the way past -- the shape
    {!Masc_tui_scroll} was written to end. On a wide terminal the sheet
    stopped at its last row while the state counted on to twice that, so
    scrolling back up paid off the surplus one press at a time before the
    reader saw anything move.

    Both sides ask this module now, so they answer with the same number. *)

val sheet : ?header:string list -> cols:int -> string list -> string list
(** The rows drawn at this width: optional full-width header rows, followed by
    the lines as written, or pairs of them fitted side by side once a terminal
    is wide enough to hold two. *)

