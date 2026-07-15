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
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_read_file_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

val handle_file_write :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:
    Keeper_publication_recovery_availability.turn_context ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  string

val handle_file_write_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:
    Keeper_publication_recovery_availability.turn_context ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t
(** Local writes acquire the project-root anchor and selected allowed root with
    [Eio.Path.open_dir] before Gate evaluation, then keep those directory
    capabilities through Gate evaluation and the selected effect. Atomic
    replace/patch reads the live publication-recovery provider only after Gate
    authorization and keeps the resulting lane access through recovery record,
    temp-file, and rename work. Append and exclusive create are recovery-store
    independent and therefore never read that provider. No local write is
    performed through a validated native path string.

    The project root's parent is the operator-owned capability-acquisition
    boundary. An explicit allowed root outside the project likewise requires
    an operator-owned parent; Keeper-writable components must begin below the
    opened root capability. *)

module For_testing : sig
  type created_directory_fault_stage =
    | Before_create_directory
    | Before_inspect_created_directory
    | Before_apply_directory_permissions

  type created_directory_fault

  val created_directory_fault
    :  stage:created_directory_fault_stage
    -> exception_:exn
    -> created_directory_fault

  val with_created_directory_fault
    :  created_directory_fault
    -> (unit -> 'a)
    -> 'a
end
