(** Message cursor persistence for keeper heartbeat. *)

val persist_message_cursor_updates :
  config:Coord.config ->
  Keeper_types.keeper_meta ->
  Keeper_world_observation.message_cursor_update list ->
  Keeper_types.keeper_meta
