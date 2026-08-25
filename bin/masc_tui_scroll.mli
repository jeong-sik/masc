(** How far a list of rows can scroll, and how a keypress moves within it.

    The arithmetic is four lines and it was written out fourteen times, once
    per surface, each naming its own field. Thirteen of those copies lived in
    the drawing, which meant drawing a frame corrected the state it was
    drawing from: the key handler moved the scroll without a bound and the
    renderer clamped it back on the way past.

    A bound belongs where the move happens. {!down} and {!up} normalise before
    they move, so a scroll left stale by a list that shrank answers the next
    keypress with a step from where the reader actually is rather than from a
    position that no longer exists. *)

val maximum : count:int -> height:int -> int
(** The largest scroll that still shows content. *)

val normalize : count:int -> height:int -> int -> int
(** A scroll held inside {!maximum}. Reading is safe on a stale value; it is
    the moving that has to be bounded. *)

val down : count:int -> height:int -> int -> int
val up : count:int -> height:int -> int -> int

(** A row cursor over the same list. The cursor names a row, the scroll names
    a window; a keypress moves the cursor and the window follows with
    {!ensure_visible}. The same stale-value rule applies: moving normalises
    first, so a list that shrank answers from its last row, not from a row
    that no longer exists. *)

val cursor_normalized : count:int -> int -> int
(** The cursor clamped into [0, count-1]; 0 when the list is empty. *)

val cursor_down : count:int -> int -> int
val cursor_up : count:int -> int -> int

val ensure_visible : cursor:int -> height:int -> int -> int
(** The smallest move of [scroll] that keeps [cursor] inside the window. *)
