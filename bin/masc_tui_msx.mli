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

val set_synchronized_output : bool -> unit
(** Use the executable's existing terminal synchronization policy. *)

val invalidate : unit -> unit
(** Forget the last accepted frame after another surface owns the terminal. *)

val set_cell_pixels : (int * int) option -> unit
(** Tell the spectator what one character cell measures, so an image placement
    can be sized to stay inside the screen. [None] leaves it sizing in cells
    alone. Set once at startup from the terminal probe, for the same reason
    {!set_graphics_protocol} is: this screen cannot reach the reader's state. *)

val render :
  write:(string -> unit)
  -> connection:Masc_tui_types.connection_status
  -> live:Masc_tui_machine_live.view
  -> ?interaction:Masc_tui_types.machine_interaction
  -> ?notice:string
  -> ?room:(width:int -> height:int -> string list)
  -> ?room_footer:string
  -> Masc_tui_types.msx_frame option
  -> Masc_tui_interactive.frame option
  -> unit
(** Retain Kitty pixels across polls, repainting only changed pixels. Other
    terminals use the truecolor mosaic. Layout changes repaint the whole terminal.
    [room] renders public conversation in its allocated cell rectangle, beside
    the picture when wide and beneath it when narrow. [room_footer] overrides
    the game hints while its composer owns input; an empty string preserves them.

    The first frame carries the observation meta (title line); the second is
    the surface contract's picture this renderer draws (RFC
    msx-surface-focus-mode stage 1) — the renderer reads pixels only through
    it and never from the meta's pixel fields.

    [None] is drawn as an empty body under a line that says why it is empty.
    [live] is the last live read of the MSX machine: a failed read is drawn
    as its error, and before any answer [connection] decides the reason, so
    "no machine loaded" never stands for a server that is down. A frame with
    no [msx_meta] came from the live read and is titled by its frame number
    alone. *)

val render_live :
  write:(string -> unit)
  -> connection:Masc_tui_types.connection_status
  -> ?activity:Masc_tui_machine_live.activity_entry list
  -> ?room:(width:int -> height:int -> string list)
  -> ?room_footer:string
  -> Masc.Machine_lane.t
  -> Masc_tui_machine_live.view
  -> unit
(** Draw a machine the spectator reads only through the live route (DOS):
    its picture scaled the way an MSX frame is, a title naming its time or
    why there is no picture, and a footer with the keys this screen answers
    for it ([esc] and the size keys).

    [activity] is recent Keeper activity on the machine, newest first. Without
    [room], it occupies the existing fixed-width sidebar when {!shows_sidebar}
    permits. With [room], actual activity entries occupy up to half of that
    region's rows beneath the conversation, after reserving its heading,
    one message row and composer, clipped to its allocated width:
    the room column at 80+ columns, or the room strip beneath the picture at
    narrower widths. No room rows are reserved for an empty feed, and activity
    never reduces the picture's existing room-aware width. *)

val sidebar_cols : int
val min_picture_cols : int
(** The two numbers {!shows_sidebar} and {!picture_cols} weigh against a
    terminal's width: the sidebar's own fixed width, and the least the
    picture needs to still be worth drawing. Exposed so a caller -- a test
    deriving what a real terminal's width should produce, not a fake one --
    can ask the same question {!draw} asks internally instead of guessing
    the two numbers again. *)

val shows_sidebar : cols:int -> has_activity:bool -> bool
(** Whether {!render_live} draws the activity column at this width: there is
    something to show, and the picture would still have {!min_picture_cols}
    left over after giving the sidebar its {!sidebar_cols}. *)

val picture_cols : cols:int -> has_activity:bool -> int
(** The picture's own column budget: [cols] less the sidebar and its gap
    where {!shows_sidebar} holds, [cols] unchanged otherwise. *)

val adjust_size : float -> unit
(** Step the picture's share of this terminal's screen by an eighth, clamped
    between a quarter and full. A local view setting -- the machine's frame
    is the server's and is never resized. *)

val server_key : string -> string option
(** The MSX lane's name for a key the human typed on the MSX screen
    ([masc_msx_press]), or [None] when the key is not a game key: space, the
    arrows, Return, Backspace and one printable character. Esc and the
    spectator's own keys are handled before this is asked. *)

val consume : write:(string -> unit) -> Masc_tui_types.state -> string -> bool
(** One key while open. [esc] closes the screen and returns [false] (the caller
    then owes the normal frame a full repaint). Every other key repaints the
    cached frame and returns [true]; keys are not sent to the machine in this
    increment. *)

val close : write:(string -> unit) -> Masc_tui_types.state -> unit
(** Delete any terminal image placement and retire the renderer when its
    workspace is withdrawn or the operator closes it. The caller must also
    invalidate the ordinary frame presenter. *)

(** {1 The load menu (RFC-0439 §3.7)}

    The human picks a game from the cartridge inventory. It is an overlay on the
    MSX screen: while [state.msx_menu_open] the keyboard drives the picker, so a
    key never reaches the emulator. The load itself is HTTP, which lives in the
    executable layer; this module draws the picker and reports the chosen row so
    the caller does the I/O and owns the [msx_menu_open]/[msx_open] lifecycle. *)

type menu_action =
  | Stay  (** navigated or repainted; the menu is still up *)
  | Closed  (** the human pressed [esc] *)
  | Watch of Masc.Machine_lane.t
      (** spectate that machine; a row exists only while it is loaded *)
  | Swap_disk of string
  | Load of string  (** plug this cartridge in *)

val open_menu : write:(string -> unit) -> ?mode:Masc_tui_types.msx_menu_mode -> Masc_tui_types.state -> unit
(** Take the terminal over and draw the picker over the cartridge inventory
    [state.msx_carts]. The caller fetches the inventory first. Selection starts
    once the menu has one. *)

val render_menu :
  write:(string -> unit) -> ?status:string -> Masc_tui_types.state -> unit
(** Redraw the picker. [status] is a single line above the list — used to show
    why a load was refused. *)

val menu_consume :
  write:(string -> unit) -> Masc_tui_types.state -> string -> menu_action
(** One key while the menu is up. Up/down (or [k]/[j]) move the highlight and
    repaint, returning [Stay]; enter/space pick the highlighted row ([Watch] or
    [Load name]) only after it was successfully drawn in the current viewport.
    Hidden rows, a resized viewport and failed output require a repaint first.
    [esc] returns [Closed]. It never flips the open flags, so the
    caller decides what a choice or a close does. *)
