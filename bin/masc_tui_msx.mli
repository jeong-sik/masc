(** The MSX spectator screen (RFC-0439 §3.7).

    The machine lives in the server; this screen draws the frame the server
    hands over. [state.msx_open] plays the role [state.image_open] plays for a
    picture: while it is set the render loop draws no frames of its own and the
    next key belongs to this screen. The frame to draw is [state.msx_frame],
    refreshed by the loop's poll; this module only renders it. *)

val render : write:(string -> unit) -> Masc_tui_types.msx_frame option -> unit
(** Draw the frame as a truecolor mosaic, or a "no machine" line when it is
    [None] or too short. Writes the whole terminal. *)

val open_screen : write:(string -> unit) -> Masc_tui_types.state -> unit
(** Take the terminal over and draw [state.msx_frame]. The caller fetches the
    first frame before this so the screen opens on a picture, not a blank. *)

val consume : write:(string -> unit) -> Masc_tui_types.state -> string -> bool
(** One key while open. [esc] closes the screen and returns [false] (the caller
    then owes the normal frame a full repaint). Every other key repaints the
    cached frame and returns [true]; keys are not sent to the machine in this
    increment. *)
