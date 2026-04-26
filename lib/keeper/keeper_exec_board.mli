(** Keeper board tool handler — post, reply, vote, list, get. *)

val handle_keeper_board_tool
  :  meta:Keeper_types.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string
