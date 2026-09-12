(** Filesystem scanner and canonical-workspace Skill snapshot publisher. *)

type workspace
type workspace_error = Config_dir_resolver.canonical_base_path_error

type config_observation =
  | Config_text of string
  | Config_unreadable of string

type publication =
  | Published of Skill_catalog_snapshot.t
  | Unchanged of Skill_catalog_snapshot.t
  | Workspace_retired

type additional_source = {
  source : Skill_source_config.source;
  ownership_root : string;
}
type additional_source_diagnostic = {
  source_id : Skill_source_config.source_id;
  message : string;
}

val workspace_of_base_path : base_path:string -> (workspace, workspace_error) result
(** Create or return the publication authority for a canonical workspace. *)

val find_workspace_of_base_path :
  base_path:string -> (workspace option, workspace_error) result
(** Lookup only. This never creates a publication slot. *)

val refresh :
  workspace:workspace ->
  user_home:string option ->
  read_config:(unit -> config_observation) ->
  publication
(** Serialize the complete config observation, scan, reduction, and publish
    transaction for one workspace. [read_config] runs after the workspace lock
    is acquired, so an older read failure cannot arrive after and replace a
    newer valid observation. Cancellation abandons the transaction and releases
    the lock without publishing. *)

val refresh_with_sources :
  workspace:workspace -> user_home:string option ->
  sources:additional_source list ->
  read_config:(unit -> config_observation) -> publication
(** Atomically replace explicitly provided package sources and publish them
    with the normal configured sources. Later [refresh] calls retain this
    source selection. Invalid additions are diagnosed individually and cannot
    replace the configured catalog with an error. No source or read bound is
    written into runtime.toml. *)
val additional_source_diagnostics :
  workspace:workspace -> additional_source_diagnostic list
val has_additional_sources : workspace:workspace -> bool
val update_additional_sources :
  workspace:workspace -> sources:additional_source list -> (publication, string) result
(** Recompose against the last published configuration observation. This does
    not reread or modify runtime.toml, so an optional package cannot change the
    workspace's selected Skill configuration. Before initial publication it
    records the source request and returns an availability diagnostic. *)

val current : workspace:workspace -> Skill_catalog_snapshot.t option
val retire : workspace:workspace -> unit
(** Remove an inactive workspace slot. The slot is removed only if it is still
    the registered instance for the canonical workspace identity. *)

val workspace_base_path : workspace -> string
