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

(** lazygit-style 3-stage screen zoom ([+] to expand main focus, [_] to step
    back). Temporary view zoom never overwrites the reader's stored Ctrl-B or
    Ctrl-L pane preferences:
    - [Normal]: both side panes follow their stored preferences
    - [Half]: hides the right Activity pane so the main surface and left
      roster share the terminal
    - [Full]: hides both side panes so the active surface fills 100% width *)
type zoom =
  | Normal
  | Half
  | Full

val zoom_in : zoom -> zoom
(** Step one stage closer to full-screen main focus ([Normal -> Half -> Full]). *)

val zoom_out : zoom -> zoom
(** Step one stage back toward normal split ([Full -> Half -> Normal]). *)

val step_zoom :
  zoom:zoom ->
  direction:[ `In | `Out ] ->
  activity_available:bool ->
  roster_available:bool ->
  zoom option
(** Availability-aware zoom step. Stepping [`In] returns [None] when neither
    side pane can actually be hidden on the current surface/width (leaving
    stored [pane_zoom] untouched), skips stages whose pane is not shown, and
    stops once every visible side pane is already collapsed. Stepping [`Out]
    always allows returning to [Normal] even after narrowing the terminal. *)

val hides_activity : zoom -> bool
(** Whether [zoom] temporarily collapses the right Activity pane. *)

val hides_roster : zoom -> bool
(** Whether [zoom] temporarily collapses the left Keeper roster pane. *)

val zoom_label : ko:bool -> zoom -> string
(** Short status notice naming the active zoom stage. *)
