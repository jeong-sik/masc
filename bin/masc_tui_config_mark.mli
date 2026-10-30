(** The marks the two Config list panes draw in their first column, and the
    words that say what each one reads as.

    Here rather than in the renderer for the reason the other mark modules are
    here: the row and the help sheet have to draw the same glyph, and a
    {!Masc.Tui_decode.prompt_source} added later stops this module compiling
    until it has been given a mark and a word. Colour is the caller's. *)

val prompt_glyph : held_back:bool -> Masc.Tui_decode.prompt_source -> string
(** The mark for one row of the prompt registry, uncoloured. [held_back]
    outranks the source, which reads [Prompt_file] for exactly those rows: the
    file is what a turn gets, and saying so is what hides the override the
    reader still has on disk. *)

val prompt_legend : (string * string) list
(** Every prompt mark once, paired with what a row wearing it reads as. The
    shipped file draws a blank and is not a row here -- a state with no mark
    needs no word -- so the override row names the unmarked case instead. *)

val param_glyph : has_override:bool -> string
(** The mark for one row of the params list, uncoloured. *)

val param_legend : (string * string) list
(** Both param marks, paired with what a row wearing one reads as. *)
