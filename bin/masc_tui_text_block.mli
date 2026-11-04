(** Rows for a block of text that was written with line breaks.

    Each line is read through [Masc.Tui_terminal_text.sanitize_terminal_text] and wrapped
    to [max_cells]. A break in the middle keeps the blank row the author
    wrote; a run of them at either end is dropped, because a leading blank
    would take the row a caller puts its label on. *)

val rows : max_cells:int -> string -> string list

val preformatted_rows : max_cells:int -> string -> string list
(** {!rows} for text whose indentation is its structure: pretty-printed JSON,
    code, an indented list. A line keeps the spaces it opens with, up to half
    of [max_cells], and the rows it wraps to start at the same indent. {!rows}
    reads the same text as prose and drops those spaces. *)

val lines : string -> string list
(** Split at LF, removing a trailing CR only when it belongs to that LF's
    CRLF terminator. Preserve blank lines, spaces, and standalone CR,
    including a CR at the end of the text. Returned lines are raw text;
    consumers must sanitize them at the terminal display boundary. This
    performs no wrapping or trimming. *)
