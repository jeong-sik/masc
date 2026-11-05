(** A numbered list as terminal rows.

    An entry is its number, two spaces and its text. An entry wider than the
    row continues on the rows below it, indented under its own text, so its
    words are not taken for the start of the next entry. *)

val rows : max_cells:int -> string list -> string list
(** One entry per string, in the order given: [1  first], [2  second]. The
    numbers are right-aligned to the width of the last one. Text is wrapped by
    {!Masc_tui_message_layout.wrap_words}: at spaces, and a word wider than a
    row -- a model id has no spaces -- is split by it, its rows read back as the
    word and every one of them stays under its own number. A budget that leaves
    no cell for the text gives it one. An entry with no text is its number
    alone. No entries give no rows. *)
