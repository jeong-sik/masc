(** The schemes masc ships with, and the mapping that turns one into a
    palette.

    masc normally draws out of the terminal's own colours and only lifts what
    cannot be read. A reader who wants a different set of colours than their
    terminal's has nowhere to say so, and pointing them at a directory they
    have to fill first means the picker is empty the first time it opens.

    So the bundled catalog rides along. They are real base16 schemes from
    tinted-theming/schemes (MIT), the same ones the contrast harness measures,
    which is the point: what ships is what was measured. They are not palettes
    masc invented. *)

type t

val bundled : t list
(** In no particular order beyond the one they were written in. *)

val names : unit -> string list
val find : string -> t option
val name : t -> string

val light : t -> bool
(** What the scheme says about itself. Not a measurement -- for that, ask
    {!Masc_tui_color.is_light} about the background {!to_palette} produces. *)

val to_palette : t -> Masc_tui_terminal_palette.t option
(** The scheme as a palette, so a chosen theme reaches every colour by the
    same road a terminal's answer does. [None] only where a scheme's own hex
    is malformed, which for a bundled one would be a typo in this file. *)
