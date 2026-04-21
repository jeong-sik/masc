(** Keeper filesystem tool handlers — read and edit. *)

(** Issue #8490: Variant SSOT for fs write mode. Mirror in
    [Tool_shard.fs_write_mode_enum_strings] (cycle avoidance, sync
    regression test catches drift). *)
type fs_write_mode = Overwrite | Append | Patch

val fs_write_mode_to_string : fs_write_mode -> string
val fs_write_mode_of_string_opt : string -> fs_write_mode option
val all_fs_write_modes : fs_write_mode list
val valid_fs_write_mode_strings : string list

val handle_keeper_fs_read :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_fs_edit :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
