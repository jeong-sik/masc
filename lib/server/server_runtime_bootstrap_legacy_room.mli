(** Legacy-room inference for the flat-room migration path. *)

val default_room_for_flat_migration : string
val legacy_room_candidates : string -> string list
val infer_current_room_from_legacy_dirs : string -> string option
val load_current_room_or_default : string -> string -> string option
