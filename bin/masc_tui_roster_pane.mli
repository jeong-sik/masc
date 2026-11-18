type preference = Hidden | Shown
(** The roster starts hidden. Ctrl-B pins or hides it across surfaces;
    the transient Keeper navigator does not change this preference. *)

val effective_hidden : preference -> bool
val toggle_preference : preference -> cols:int -> preference option
(** Below the width threshold, return [None] and preserve the preference. *)

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

val shown : hidden:bool -> cols:int -> bool
(** [hidden] is the reader's answer, [cols] the terminal's. Both must agree. *)

val toggle_hidden : hidden:bool -> cols:int -> bool option
(** Toggle the reader's preference only where the pane can actually show.
    [None] below {!threshold_cols} leaves the preference untouched, so a key
    with no visible effect cannot surprise the reader after a later resize. *)

val content_cols : hidden:bool -> cols:int -> int
(** What the surface beside the roster lays out against. *)

val arrows_go_left : hidden:bool -> cols:int -> preferring_left:bool -> bool
(** Whether a cursor keypress belongs to the pane beside the detail.

    [preferring_left] is what the reader last asked for with h/l. It only
    counts where the pane is actually drawn: a preference for a pane that is
    not on screen is a keypress that moves something invisible. *)
