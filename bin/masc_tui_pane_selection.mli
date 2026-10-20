(** A mouse drag on the screen, kept inside the pane it started in.

    A frame is one string per terminal row, and the panes drawn beside each
    other -- the Keeper roster on the left, the surface, the Activity pane on
    the right -- are joined into those rows. The terminal's own selection
    cannot tell where one pane ends, so a drag down a chat took the roster
    and the Activity feed with it. The render records where each pane is;
    this module reads a press, the drag after it and its release as a click
    or as a selection inside one of those panes, and reads the selected text
    back from the rows on screen.

    Pure: no terminal and no clock. Rows and columns are 1-based, the way a
    mouse report counts them. *)

type pane_kind =
  | Roster  (** the Keeper roster beside a chat *)
  | Main  (** the surface, or the overlay drawn over it *)
  | Activity  (** the Activity pane on the right edge *)

type rect = { top : int; bottom : int; left : int; right : int }
(** Inclusive bounds. *)

type pane = { kind : pane_kind; rect : rect }

type layout = pane list
(** Every pane of one frame. A row that spans the terminal -- the tab strip,
    the agenda, the composer, the footer -- lies in none of them. *)

val no_panes : layout

type roster_split = { roster_cols : int; roster_rows : int }
(** The roster's columns at the left edge, beside the first [roster_rows]
    body rows. *)

val frame_layout :
  first_row:int ->
  body_rows:int ->
  main_cols:int ->
  activity_cols:int ->
  roster:roster_split option ->
  layout
(** The panes of a surface frame: its [body_rows] rows from [first_row], the
    surface in the first [main_cols] columns, and the Activity pane in the
    [activity_cols] after them. A roster takes the surface's first columns
    and its rows end the surface's pane too: a row below the split spans
    both, so it is in neither. Empty rectangles are left out. *)

val pane_at : layout -> row:int -> column:int -> pane option

type point = { row : int; column : int }

type selection = { pane : pane; anchor : point; focus : point }
(** [anchor] is the cell the press landed on and [focus] the cell the
    pointer is over now, held inside [pane]. *)

type gesture =
  | Idle
  | Pressed of { at : point; pane : pane option }
      (** The button is down and has not left [at]. *)
  | Drag_without_pane
      (** The button left a press that landed on no pane: neither a click
          nor a selection. *)
  | Selecting of selection

type outcome =
  | Click of point  (** released on the cell it was pressed on *)
  | Copy of selection
  | Nothing

val press : layout -> row:int -> column:int -> gesture
(** A new press starts a new gesture, whatever the last one was. *)

val drag : gesture -> row:int -> column:int -> gesture
(** Moving off the pressed cell makes the press a selection in its pane, the
    position held inside that pane's rectangle. *)

val release : gesture -> row:int -> column:int -> outcome
(** The release reads as a last move, then ends the gesture: a press that
    never left its cell is a click there. *)

val in_progress : gesture -> bool
(** The button is down on a gesture: Escape cancels it. *)

type span = { span_row : int; first_column : int; last_column : int }

val spans : selection -> span list
(** The selected cells of every row, top first, the way text runs: the first
    row from the earlier end to the pane's right edge, whole pane rows
    between, and the last row from the pane's left edge to the later end. *)

val highlight : selection -> string list -> string list
(** The frame's rows (row 1 first) with the selected cells drawn in reverse
    video. A wide character the selection touches is drawn whole, and a row
    shorter than its span is padded with blanks so the selection shows. *)

val text : selection -> string list -> string option
(** The plain text of the selected cells of these rows, one line per row,
    trailing spaces dropped. A wide character the selection touches is taken
    whole. [None] when every row comes out empty. *)
