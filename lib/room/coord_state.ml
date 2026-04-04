(** Coord_state — New name for Room_state.
    Coordination state: read/write/update, sequence numbers, pause control.
    Room_state remains for backward compatibility. *)
include Room_state
