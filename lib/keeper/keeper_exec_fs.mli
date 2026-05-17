(** Keeper filesystem tool handlers — read and edit. *)

val resolve_partition_for_write
  :  base_dir:string
  -> kind:string
  -> file_path:string
  -> Ide_paths.partition * string
(** RFC-0128 §4.5. Reverse-lookup helper used by [track_write_region]
    to decide which {!Ide_paths.partition} bucket a keeper write
    belongs to and what its repo-relative file path is. Exposed for
    testing so the sandbox/working-tree join invariant can be
    verified directly.

    Returns:
    - [(By_url slug, rel_path)] when the file lives under a registered
      repository whose [url] normalises via
      {!Ide_paths.canonical_url_of_remote}. [rel_path] is the path
      relative to that repository's [local_path].
    - [(Orphan, original_path)] otherwise. Increments
      [masc_ide_orphan_writes_total] with the failure reason label
      ([unregistered_repo] / [blank_url] / [url_unparseable]).

    [kind] selects the metric label ([annotation] or [region]). *)

(** Issue #8490: Variant SSOT for fs write mode. Mirror in
    [Tool_shard.fs_write_mode_enum_strings] (cycle avoidance, sync
    regression test catches drift). *)
type fs_write_mode = Overwrite | Append | Patch

val fs_write_mode_to_string : fs_write_mode -> string
val fs_write_mode_of_string_opt : string -> fs_write_mode option
val all_fs_write_modes : fs_write_mode list
val valid_fs_write_mode_strings : string list

val handle_keeper_fs_read :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Coord.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_fs_edit :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Coord.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  string
