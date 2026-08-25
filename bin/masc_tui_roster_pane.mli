(** Whether the keeper roster shares the screen with what it sits beside.

    Two things decide it and they are not the same kind of fact. The terminal
    decides whether there are columns to spare; the reader decides whether
    they want the list at all. Keeping them separate is what lets a reader put
    the roster away and have it stay away across a resize -- a decision is not
    a measurement. *)

val threshold_cols : int
(** The width from which a surface can afford the roster beside it. *)

val pane_cols : int
(** The columns the roster takes when it shows. *)

val marquee_offset : frame:int -> overflow:int -> int
(** Ping-pong offset for a selected name that is [overflow] cells wider than
    its window. The motion pauses at both ends; a non-positive frame or
    overflow starts at zero. *)

val name_window : selected:bool -> frame:int -> width:int -> string -> string
(** Fit a keeper name to exactly [width] terminal cells. An unselected name is
    statically truncated. A selected long name uses {!marquee_offset} and
    leaves an ellipsis on each side that still has hidden text. *)

val shown : hidden:bool -> cols:int -> bool
(** [hidden] is the reader's answer, [cols] the terminal's. Both must agree. *)

val content_cols : hidden:bool -> cols:int -> int
(** What the surface beside the roster lays out against. *)
