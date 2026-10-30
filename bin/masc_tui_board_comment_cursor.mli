(** The Board reader's comment cursor: a comment id over the order the thread
    is drawn in. Kept as an id rather than a row or an index, so a refresh
    that adds, removes or rescores comments leaves it on the same comment. *)

val ordered_ids : Masc_tui_types.board_comment list -> string list
(** Comment ids in {!Masc_tui_board_comment_thread.order}, the order the
    column draws them and the order j/k walk. *)

val resolve : string list -> string option -> string option
(** The cursor while [ids] still holds it, otherwise [None]. *)

val select : string list -> landing:string option -> string option -> string option
(** The comment a focus change or a vote key selects: the cursor if it is
    still drawn, otherwise the comment the read landed on, otherwise the first
    drawn comment. [None] only for an empty thread. *)

val move :
  string list -> landing:string option -> string option -> delta:int ->
  string option
(** [delta] comments along the drawn order, stopping at either end. A cursor
    that is not drawn does not move by [delta]; it takes {!select}'s answer,
    so the first j on a thread selects rather than skips a comment. *)

val reveal_scroll :
  scroll:int -> viewport_rows:int -> first_row:int -> row_count:int -> int
(** The comment column's scroll after it is moved the least that puts the
    comment spanning [row_count] rows from [first_row] on screen. A comment
    above the view comes to its top row; one below rests on its last row; one
    taller than [viewport_rows] shows its first row, so its author and time
    are what a reader sees first. *)
