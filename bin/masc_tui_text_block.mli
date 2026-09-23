(** Rows for a block of text that was written with line breaks.

    Each line is read through [Tui_decode.sanitize_terminal_text] and wrapped
    to [max_cells]. A break in the middle keeps the blank row the author
    wrote; a run of them at either end is dropped, because a leading blank
    would take the row a caller puts its label on. *)

val rows : max_cells:int -> string -> string list
