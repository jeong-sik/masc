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
