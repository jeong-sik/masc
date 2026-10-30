(** The marks the Memory roster draws in its ST column, and the words that say
    what each one reads as.

    Here rather than in the renderer so the column and the help sheet cannot
    drift: both read the same glyph from the same function, and a state added
    to {!Masc_tui_types.memory_state} stops this module compiling until it has
    been given a mark. Colour is the caller's. *)

val glyph : Masc_tui_types.memory_state -> string
(** The mark for one keeper's memory reading, uncoloured. *)

val legend : (string * string) list
(** Every mark once, paired with what a row wearing it reads as. Two states
    share the attention mark and two share the failure mark, so this is
    shorter than {!Masc_tui_types.memory_state} has constructors. *)
