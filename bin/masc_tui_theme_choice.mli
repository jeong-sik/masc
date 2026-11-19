(** Which colours this reader wants, as opposed to which colours their
    terminal reports.

    Everything else on the Config surface is a file the server reads. This is
    not: no server has an opinion about the colours a terminal draws, and two
    readers on one workspace can want different ones. Choosing here changes
    only the chooser's screen. *)

type entry =
  { name : string
  ; light : bool
        (** What the scheme says about itself, not a measurement. *)
  ; measured : int  (** How many colours were checked. *)
  ; lifted : int
        (** How many measured scheme colours start below the readable floor.
            Output capability determines whether they can be lifted. *)
  ; swatch : Masc_tui_terminal_palette.rgb list
        (** The colours a row can draw beside the name, in the order masc
            reads meaning from them, plus the page they sit on. A name tells a
            reader nothing about whether they will like it; these do. *)
  }

val entries : unit -> entry list
(** Every bundled scheme with its unadjusted values measured against the same
    floor the renderer targets. Native-pass schemes come first; equal counts
    of colours below the floor are ordered by name. *)

val swatch_cells : entry -> string
(** [entry]'s colours drawn as two-cell blocks, ending back on the terminal's
    own page. The picker shows a colour for its own sake, which no other
    surface does, so the escape is made here rather than by the renderer. *)

val contrast_status : entry -> string
(** A compact, explicit reading of the measurement. [native 7/7] means every
    measured scheme colour clears the floor; [3/7 low] means three start
    below it. Neither reports whether the terminal applied the scheme. *)

val default_truecolor_theme : string
(** Bundled Truecolor default scheme applied on Truecolor terminals when no
    explicit theme preference (nor terminal-follow sentinel) is stored. *)

val terminal_choice_name : string
(** Sentinel stored in [runtime.toml] when the operator explicitly chooses to
    follow the terminal's own colours instead of the Truecolor default. *)

val apply : string -> bool
(** Draw with this scheme's colours from now on, enabling direct 24-bit
    Truecolor RGB output on Truecolor terminals. [false] for a name no
    bundled scheme answers to, so a stale choice in a config file cannot
    silently leave the reader on colours nobody picked.

    Published through the palette's generation, so the screen repaints the
    same way it does when the terminal reports a theme switch of its own. *)

val follow_terminal : unit -> unit
(** Go back to the terminal's own colours (disabling direct Truecolor RGB
    override and restoring the last observed terminal palette, if any). *)

val record_terminal_palette : Masc_tui_terminal_palette.t option -> unit
(** Remember the palette reported by the terminal's OSC probe. Updates the
    active palette only when following the terminal so an active TUI theme is
    not overwritten by a late OSC reply. *)

val invalidate_cache : unit -> unit
(** Invalidate cached entries so the next call to [entries] reloads from disk. *)
