(** Pure projection of the mutable TUI state into the composer reading shared
    by rendering and input routing. *)

val source_reading : Masc_tui_types.state -> Masc_tui_composer.reading
(** Constant-time source observation for a surface that only needs startup/read
    information. Does not find a Keeper, inspect a draft or decide input authority. *)

val of_state : Masc_tui_types.state -> Masc_tui_composer.t
(** Snapshot the selected recipient, authoritative availability, current metadata
    observation, focus, and draft. Pending stages come only from the original
    metadata source; optional Work never supplies them.
    This is the only owner of the state-to-composer projection; it performs no
    reads or effects beyond the supplied in-memory state. *)
