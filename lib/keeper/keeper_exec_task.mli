(** Keeper task coordination tool handler — claim, transition, list. *)

val handle_keeper_task_tool
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> string
