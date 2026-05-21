(** Message cursor persistence for keeper heartbeat. *)

val persist_message_cursor_updates :
  config:Coord.config ->
  Keeper_types.keeper_meta ->
  (string * int) list ->
  Keeper_types.keeper_meta
