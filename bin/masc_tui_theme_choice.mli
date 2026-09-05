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
        (** How many of them this scheme leaves under the readable floor, so
            masc has to lift them. Zero means the scheme's author already
            cleared it everywhere masc looks -- the quiet answer, not the
            empty one. *)
  ; swatch : Masc_tui_terminal_palette.rgb list
        (** The colours a row can draw beside the name, in the order masc
            reads meaning from them, plus the page they sit on. A name tells a
            reader nothing about whether they will like it; these do. *)
  }

val entries : unit -> entry list
(** Every bundled scheme with what picking it would cost, measured against
    the same floor the renderer lifts to. Native-pass schemes come first;
    equal lift counts are ordered by name. *)

val contrast_status : lift_on:bool -> entry -> string
(** A compact, explicit reading of the measurement. [native 7/7] means every
    measured colour clears the floor without help; [lift 3/7] means the lift
    raises three; [3/7 low] means those three remain below it because the lift
    is disabled. *)

val apply : string -> bool
(** Draw with this scheme's colours from now on. [false] for a name no
    bundled scheme answers to, so a stale choice in a config file cannot
    silently leave the reader on colours nobody picked.

    Published through the palette's generation, so the screen repaints the
    same way it does when the terminal reports a theme switch of its own. *)

val follow_terminal : unit -> unit
(** Go back to the terminal's own colours. *)

val invalidate_cache : unit -> unit
(** Invalidate cached entries so the next call to [entries] reloads from disk. *)
