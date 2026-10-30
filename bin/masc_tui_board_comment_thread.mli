(** Board comments as the thread they were written as.

    The store and the wire have carried [parent_id] since comments existed;
    the pane decoded a flat list, so a reply and the thing it answered sat at
    one indent in clock order and a discussion read as unrelated remarks. *)

val order :
  Masc_tui_types.board_comment list ->
  (int * Masc_tui_types.board_comment) list
(** Reading order with each comment's depth: every reply follows the comment it
    answers and every sibling keeps the order it arrived in.

    Total on any input. A [parent_id] naming a comment this page does not hold
    -- a reply whose parent expired, or one the pagination cut -- reads at the
    top level rather than disappearing, and a cycle cannot hide a row either.
    Losing a comment is worse than drawing it at the wrong indent. *)

val rail : depth:int -> string
(** The indent drawn ahead of a comment at [depth], as plain cells. Depth 0 is
    empty, so a flat thread draws exactly what it drew before this existed. *)

val max_depth : int
(** Where the indent stops growing. Past it a reply keeps the deepest rail
    rather than walking off a narrow pane; the order still nests. *)
