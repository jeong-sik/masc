(** Keeper task coordination tool handler — claim, transition, list. *)

val handle_keeper_task_tool :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
