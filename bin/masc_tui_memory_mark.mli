(** The marks the Memory roster draws in its ST column, and the words that say
    what each one reads as.

    Here rather than in the renderer so the column and the help sheet cannot
    drift: both read the same glyph from the same function, and a state added
    to {!Masc_tui_types.memory_state} stops this module compiling until it has
    been given a mark. Colour is the caller's. *)

val mark : Masc_tui_types.memory_state -> Masc_tui_value.Mark.t
(** The status mark one keeper's memory reading wears (RFC
    tui-one-screen-grammar, section 7.2). *)

val glyph : Masc_tui_types.memory_state -> string
(** {!mark} as its glyph, uncoloured. *)

val legend_for : ko:bool -> (string * string) list
(** Every mark once, paired with what a row wearing it reads as. Four states
    share the caution mark and two share the failure mark, so this is
    shorter than {!Masc_tui_types.memory_state} has constructors. The words of
    the header's world line follow, from {!Masc_tui_memory_world.legend_for}. *)
