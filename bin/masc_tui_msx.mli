(** The MSX spectator screen (RFC-0439 §3.7).

    The machine lives in the server; this screen draws the frame the server
    hands over. [state.msx_open] plays the role [state.image_open] plays for a
    picture: while it is set the render loop draws no frames of its own and the
    next key belongs to this screen. The frame to draw is [state.msx_frame],
    refreshed by the loop's poll; this module only renders it. *)

val set_graphics_protocol : Masc_tui_graphics.graphics_protocol -> unit
(** Tell this screen what the boot probe found. A terminal that draws images
    gets the frame's own pixels; every other one gets the block mosaic, which
    is also what an unset protocol means.

    Set once at startup from the same value the other image surfaces read, so
    the spectator and the image overlay cannot disagree about what the
    terminal can do. *)

val set_cell_pixels : (int * int) option -> unit
(** Tell the spectator what one character cell measures, so an image placement
    can be sized to stay inside the screen. [None] leaves it sizing in cells
    alone. Set once at startup from the terminal probe, for the same reason
    {!set_graphics_protocol} is: this screen cannot reach the reader's state. *)

val render :
  write:(string -> unit)
  -> connection:Masc_tui_types.connection_status
  -> ?notice:string
  -> Masc_tui_types.msx_frame option
  -> unit
(** Draw the frame as a truecolor mosaic. Writes the whole terminal.

    [None] is drawn as an empty body under a line that says why it is empty,
    and [connection] is what decides which reason. The cache is [None] both
    when the server said no machine is loaded and when it could not be reached
    to say anything -- {!Masc_tui_http.fetch_msx_frame} maps a transport
    failure onto the same value -- and "no machine loaded" sends an operator to
    load one when the server is the thing that is down. *)

val adjust_size : float -> unit
(** Step the picture's share of this terminal's screen by an eighth, clamped
    between a quarter and full. A local view setting -- the machine's frame
    is the server's and is never resized. *)

val consume : write:(string -> unit) -> Masc_tui_types.state -> string -> bool
(** One key while open. [esc] closes the screen and returns [false] (the caller
    then owes the normal frame a full repaint). Every other key repaints the
    cached frame and returns [true]; keys are not sent to the machine in this
    increment. *)

(** {1 The load menu (RFC-0439 §3.7)}

    The human picks a game from the cartridge inventory. It is an overlay on the
    MSX screen: while [state.msx_menu_open] the keyboard drives the picker, so a
    key never reaches the emulator. The load itself is HTTP, which lives in the
    executable layer; this module draws the picker and reports the chosen row so
    the caller does the I/O and owns the [msx_menu_open]/[msx_open] lifecycle. *)

type menu_action =
  | Stay  (** navigated or repainted; the menu is still up *)
  | Closed  (** the human pressed [esc] *)
  | Watch  (** spectate the machine that is already loaded *)
  | Swap_disk of string
  | Load of string  (** plug this cartridge in *)

val open_menu : write:(string -> unit) -> ?mode:Masc_tui_types.msx_menu_mode -> Masc_tui_types.state -> unit
(** Take the terminal over and draw the picker over the cartridge inventory
    [state.msx_carts]. The caller fetches the inventory first. Selection starts
    at the top row. *)

val render_menu :
  write:(string -> unit) -> ?status:string -> Masc_tui_types.state -> unit
(** Redraw the picker. [status] is a single line above the list — used to show
    why a load was refused. *)

val menu_consume :
  write:(string -> unit) -> Masc_tui_types.state -> string -> menu_action
(** One key while the menu is up. Up/down (or [k]/[j]) move the highlight and
    repaint, returning [Stay]; enter/space pick the highlighted row ([Watch] or
    [Load name]); [esc] returns [Closed]. It never flips the open flags, so the
    caller decides what a choice or a close does. *)
