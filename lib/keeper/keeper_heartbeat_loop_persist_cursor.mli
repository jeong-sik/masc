(** Message cursor persistence for keeper heartbeat loop state. *)

val persist_message_cursor_updates :
  config:Coord.config ->
  Keeper_types.keeper_meta ->
  (string * int) list ->
  Keeper_types.keeper_meta
(** Merge message cursor updates into keeper metadata and persist them with
    concurrent-write protection. *)
