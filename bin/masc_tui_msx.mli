(** The MSX screen: a whole-terminal spectator over the emulator core.

    [state.msx_open] plays the role [state.image_open] plays for a picture:
    while it is set the render loop draws no frames, and the next key belongs
    to this screen rather than to the surface underneath. The machine outlives
    the screen -- closing it is closing the window, not switching the computer
    off, so reopening continues the same frame.

    The core is the stub from ocaml-msx: no Z80, no VDP, a deterministic test
    pattern. What this module proves is the attachment -- terminal takeover,
    key injection, frame stepping -- so the core can be replaced under it
    without this file changing. *)

val open_screen : write:(string -> unit) -> Masc_tui_types.state -> unit
(** Take the terminal over and draw the current frame. Creates the machine on
    first use; later opens keep the machine and its frame. *)

val consume : write:(string -> unit) -> Masc_tui_types.state -> string -> bool
(** Read one key while the screen is open. [esc] closes the screen; arrows,
    space, and single printable characters are injected into the machine, and
    every key steps one frame and redraws. Returns whether the screen is still
    open -- [false] is the key that closed it, and the caller then owes the
    normal frame a full repaint, the same debt [close_image] leaves. *)
