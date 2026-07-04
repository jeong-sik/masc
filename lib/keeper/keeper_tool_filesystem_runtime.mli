(** Filesystem runtime handlers for descriptor-backed Read/Edit/Write tools. *)

val resolve_partition_for_write
  :  base_dir:string
  -> kind:string
  -> file_path:string
  -> Agent_observation.codebase_partition * string
(** RFC-0128 §4.5. Reverse-lookup helper used by [track_write_region]
    to decide which neutral observation partition a keeper write
    belongs to and what its repo-relative file path is. Exposed for
    testing so the sandbox/working-tree join invariant can be
    verified directly.

    Returns:
    - [(By_url slug, rel_path)] when the file lives under a registered
      repository whose [url] normalises via
      {!Agent_observation.canonical_url_of_remote}. [rel_path] is the path
      relative to that repository's [local_path].
    - [(No_canonical_url, original_path)] when a matched repository has a blank
      or malformed [url].
    - [(Base_unresolved, original_path)] when no registered repository contains
      the path.
    - [(Unmatched, original_path)] when a sandbox playground [repo_id] cannot
      be found in the repository store.

      The three non-[By_url] variants all write under the shared
      [.masc-ide/_orphan/] directory, but keep the typed reason in memory and
      in emitted observation records. Increments [masc_ide_orphan_writes_total]
      with the concrete failure reason label ([unregistered_repo] /
      [blank_url] / [url_unparseable] / sandbox variants).

    [kind] selects the metric label ([annotation] or [region]). *)

(** Issue #8490: Variant SSOT for filesystem write mode. Mirror in
    [Tool_shard_types.fs_write_mode_enum_strings] (cycle avoidance, sync
    regression test catches drift). *)
type fs_write_mode = Overwrite | Append | Patch

val fs_write_mode_to_string : fs_write_mode -> string
val fs_write_mode_of_string_opt : string -> fs_write_mode option
val all_fs_write_modes : fs_write_mode list
val valid_fs_write_mode_strings : string list

val handle_read_file :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  string

val handle_file_write :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  string
