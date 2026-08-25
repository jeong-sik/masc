(** Pure projection of the mutable TUI state into the composer reading shared
    by rendering and input routing. *)

val of_state : Masc_tui_types.state -> Masc_tui_composer.t
(** Snapshot the selected recipient, roster availability, focus, and draft.
    This is the only owner of the state-to-composer projection; it performs no
    reads or effects beyond the supplied in-memory state. *)
