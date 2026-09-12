(** The rows a surface actually draws, cut out of the list it holds.

    Every listing drew its window by asking the list for row [scroll + i],
    once per visible row. A list answers that by walking from the front, so a
    forty-row window twenty thousand rows down cost eight hundred thousand
    steps -- per frame, and frames come as fast as sixty a second while a key
    is held. Measured on the Code surface with this repository's own
    {v masc_tui.ml v} open (21,158 rows, window at the end): 169.8 ms of
    every second spent walking, against 4.0 ms for the same second here.

    Cut once instead. One pass reaches the window and stops; nothing outside
    it is visited, and nothing is retained between frames, so there is no
    cache to go stale under a list that changed while the reader looked at
    it.

    Rows are named by their index in the whole list, not by their position in
    the window. That is the number every listing already had -- it marks the
    cursor row, it indexes into a parallel list, it goes into the row's own
    label -- so adopting this module moves the lookup and leaves the
    arithmetic around it alone. *)

type 'a t

val of_list : first:int -> height:int -> 'a list -> 'a t
(** The [height] rows from index [first], or fewer when the list ends first.
    A negative [first] reads as the top of the list and a negative [height]
    as no rows: both are read off state a keypress moved, and a window is not
    where a missing clamp should first be noticed. *)

val of_array : 'a array -> 'a t
(** Every row, as a window over the whole thing. For a surface that already
    holds its rows in an array and asks for scattered indices rather than a
    run -- the Code diff pane resolves a drawn row's colouring by that row's
    line number in the file -- so that it reads rows through [at] like every
    other listing. The array is shared, not copied. *)

val at : 'a t -> int -> 'a option
(** The row at that index {i in the whole list}. [None] outside the window,
    which is the blank row the listings already draw past the end -- and is
    also the answer for a row the window does not reach, so a loop that runs
    past its own height draws blanks rather than another surface's rows. *)

val length : 'a t -> int
(** Rows in the window. Below the asked-for height when the list ran out. *)
