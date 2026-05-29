(** Message cursor persistence for keeper heartbeat. *)

val persist_message_cursor_updates :
  config:Coord.config ->
  Keeper_meta_contract.keeper_meta ->
  (string * int) list ->
  Keeper_meta_contract.keeper_meta
