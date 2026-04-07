(** Keeper filesystem tool handlers — read and edit. *)

val handle_keeper_fs_read :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_fs_edit :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
