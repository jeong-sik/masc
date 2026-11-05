(** A numbered list as terminal rows.

    An entry is its number, two spaces and its text. An entry wider than the
    row continues on the rows below it, indented under its own text, so its
    words are not taken for the start of the next entry. *)

val rows : max_cells:int -> string list -> string list
(** One entry per string, in the order given: [1  first], [2  second]. The
    numbers are right-aligned to the width of the last one. Text is wrapped at
    spaces by {!Masc_tui_message_layout.wrap_words}; a budget that leaves no
    cell for the text gives it one. An entry with no text is its number alone.
    No entries give no rows. *)
