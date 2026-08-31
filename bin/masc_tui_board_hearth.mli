(** Which sub-board the Board list is narrowed to.

    A hearth is the Board's own topic axis, and the server has always taken it
    as a listing filter. The pane drew the column and offered no way to use it,
    on a board where 1550 of 2171 posts sit in [verification] alone: a flat
    list is 71% one topic with nothing saying so. *)

val vocabulary : Masc_tui_types.board_post list -> string list
(** The hearths a listing showed, busiest first and ties by name, so cycling
    reaches the crowded ones in a press or two. Posts with no hearth
    contribute nothing.

    Read only off an unnarrowed listing. A narrowed one shows exactly the
    hearth already selected, so refreshing the vocabulary from it would
    collapse the cycle to that one and leave no key back out to a third. *)

val next : current:string option -> vocabulary:string list -> string option
(** The next narrowing after [current]: [None] (every hearth), then each of
    [vocabulary] in turn, then [None] again.

    A [current] the vocabulary no longer holds returns to [None] rather than
    guessing a neighbour -- the hearth it named is gone from the board, and
    the whole board is the honest answer to "what comes after it". *)
