(** Room current-room helpers.
    Keeps the current-room pointer durable. *)

val current_room_path : Room_utils.config -> string
val read_current_room : Room_utils.config -> string option
val write_current_room : Room_utils.config -> string -> unit
val room_path : Room_utils.config -> string -> string
