(** The marks the Board draws in its leftmost column, and the words that say who
    put the post there.

    Here rather than in the renderer so the column and the help sheet cannot
    drift: both read the same glyph from the same function, and a kind added to
    {!Masc_tui_types.board_post_kind} stops this module compiling until it has
    been given a mark and a word. Colour is the caller's. *)

type kind =
  | Person
  | Automation
  | Unknown

val glyph : Masc_tui_types.board_post_kind option -> string
(** The mark for one post, uncoloured. The system's posts and a post whose kind
    the wire did not say both get a blank: two thirds of this board is the
    system's, and marking the majority marks nothing. *)

val legend : (string * string) list
(** Every mark that is not a blank, paired with the word for who wrote it. *)

val kinds : kind list
(** Every {!kind}, in {!legend} order. *)
