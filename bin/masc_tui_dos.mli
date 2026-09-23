(** The DOS spectator screen (#38424).

    The machine lives in the server; this screen draws the frame the server
    hands over, through {!Masc_tui_machine_view}. It is read-only: the poll
    never moves the machine's time, and no key pressed here is sent to the
    machine. [state.dos_open] plays the role [state.msx_open] plays for the MSX
    screen: while it is set the render loop draws no frames of its own and
    every key belongs to this screen. *)

type key_action =
  | Close  (** [esc]: hand the terminal back *)
  | Resize of float  (** [+]/[=] grow, [-]/[_] shrink the picture an eighth *)
  | Repaint  (** every other key: redraw the cached frame, send nothing *)

val key_action : string -> key_action

val title_of :
  connection:Masc_tui_types.connection_status -> Masc_tui_types.dos_frame option -> string
(** The title row: the program, who holds the controller, and the step count.
    With no frame it says why -- no machine loaded, or the server could not be
    asked -- and [connection] decides which. Names from the wire are put
    through the terminal sanitiser. *)

val footer : unit -> string

val render :
  write:(string -> unit)
  -> connection:Masc_tui_types.connection_status
  -> ?notice:string
  -> Masc_tui_types.dos_frame option
  -> unit

val consume : write:(string -> unit) -> Masc_tui_types.state -> string -> bool
(** One key while open. [esc] closes the screen and returns [false] (the
    caller then owes the normal frame a full repaint). Every other key
    returns [true] after resizing or repainting. *)
