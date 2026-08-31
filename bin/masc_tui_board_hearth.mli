(** Which sub-board the Board list is narrowed to.

    A hearth is the Board's own topic axis, and the server has always taken it
    as a listing filter and counted it as a census. The pane drew the column
    and offered no way to use it, on a board where one hearth holds most of
    the posts: a flat list is mostly one topic with nothing saying so. *)

val next :
  current:string option -> census:(string * int) list -> string option
(** The next narrowing after [current]: [None] (every hearth), then each name
    in [census] in turn, then [None] again. [census] is the board's own count
    of every hearth, busiest first, so the cycle reaches the crowded ones in a
    press or two and can offer a hearth whose posts all fall outside the page
    on screen.

    A [current] the census no longer holds returns to [None] rather than
    guessing a neighbour -- the hearth it named is gone from the board, and
    the whole board is the honest answer to "what comes after it". *)
