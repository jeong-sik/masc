(** Pure terminal mouse grammar. Coordinates remain one-based (row, column);
    input buffering and gesture ownership belong to the input reader. *)

(** Which way a wheel notch turned. *)
type wheel_direction =
  | Wheel_up
  | Wheel_down

(** The key a notch becomes for a surface's scroll binding: [wheel-up] /
    [wheel-down], its own rather than the arrow's. *)
val wheel_key : wheel_direction -> string

(** Decode one SGR mouse report into a wheel notch and its [(row, column)],
    1-based as the terminal reports it, or [None] for reports nothing consumes
    (clicks, releases, horizontal wheel). The position is what lets the loop
    give the notch to the Activity pane under it and every other notch to the
    surface. [parameters] is the raw CSI parameter span (["<64;10;5"]),
    [final] the CSI final byte. *)
val sgr_wheel_report : string -> char -> (wheel_direction * int * int) option

(** Decode one SGR mouse report into the [(row, column)] of an unmodified
    left-button press (button [0], final [M]), 1-based as the terminal
    reports it. Releases, modifier chords, drags and wheel reports return
    [None] — acting on those would double-fire or claim a gesture nobody
    meant. *)
val sgr_left_press : string -> char -> (int * int) option

(** A legacy X10 mouse report, read into the events an SGR report gives.
    Positions are 1-based and row/column ordered. [X10_other_press] is a
    middle, right or modified press, which no surface reads. [X10_release] is
    X10's one release code, which does not say which button went up. *)
type x10_mouse =
  | X10_wheel of wheel_direction * int * int
  | X10_left_press of int * int
  | X10_other_press
  | X10_release of int * int

(** Decode the three raw bytes after [CSI M]: button, column, row, each offset
    by 32. Terminals without SGR ([?1006]) support answer the tracking request
    in this shape; Apple Terminal, the macOS default, is one. Motion reports,
    the horizontal wheel and a position below 1 are [None]; the caller consumes
    the bytes either way. *)
val x10_mouse_report :
  button:char -> column:char -> row:char -> x10_mouse option

val sgr_left_release : string -> char -> (int * int) option
(** Plain SGR left release position for screenshot click/drag gestures. *)
