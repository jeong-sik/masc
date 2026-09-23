(** The picture half of a machine spectator (the MSX and DOS screens).

    Both screens draw one server frame over the whole terminal: a title row,
    an optional notice row, the picture, and a footer on the last row. The
    picture is the frame's own pixels on a terminal that speaks the kitty
    graphics protocol and a truecolour block mosaic everywhere else. Only one
    spectator owns the terminal at a time, so the retained frame and the size
    choice live here, not in each screen. *)

val set_graphics_protocol : Masc_tui_graphics.graphics_protocol -> unit
(** Tell the spectators what the boot probe found. A terminal that draws
    images gets the frame's own pixels; every other one gets the block mosaic,
    which is also what an unset protocol means.

    Set once at startup from the same value the other image surfaces read, so
    a spectator and the image overlay cannot disagree about what the terminal
    can do. *)

val set_synchronized_output : bool -> unit
(** Use the executable's existing terminal synchronization policy. *)

val set_cell_pixels : (int * int) option -> unit
(** Tell the spectators what one character cell measures, so an image
    placement can be sized to stay inside the screen. [None] leaves it sizing
    in cells alone. Set once at startup from the terminal probe, for the same
    reason {!set_graphics_protocol} is: a spectator cannot reach the reader's
    state. *)

val invalidate : unit -> unit
(** Forget the last accepted frame after another surface owns the terminal. *)

val fit_line : int -> string -> string
(** The first [width] bytes of a line, at least one. *)

val adjust_size : float -> unit
(** Step the picture's share of this terminal's screen by an eighth, clamped
    between a quarter and full. A local view setting -- the machine's frame
    is the server's and is never resized. *)

val size_percent : unit -> int
(** The picture's share of the screen, for a footer to show. *)

val draw :
  write:(string -> unit)
  -> title:string
  -> ?notice:string
  -> footer:string
  -> retain:bool
  -> Masc_tui_interactive.frame option
  -> unit
(** Draw [title], [notice], the picture and [footer]. Kitty pixels are
    retained across calls and sent again only when they change; a layout
    change repaints the whole terminal. [retain] says the picture is worth
    keeping for {!last_surface}; an empty screen passes [false]. *)

val last_surface : unit -> Masc_tui_interactive.frame option
(** The picture the last retained {!draw} drew, for a repaint. *)

val release : write:(string -> unit) -> unit
(** The spectator hands the terminal back: forget the retained frame and take
    its image off the screen. *)

val draw_text_screen : write:(string -> unit) -> (Buffer.t -> unit) -> unit
(** Draw a text screen in the spectator's place (the MSX load menu): clears
    any picture, lets the caller write the rows into the buffer, and leaves no
    image behind. *)
