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

val current : workspace:workspace -> Skill_catalog_snapshot.t option
val retire : workspace:workspace -> unit
(** Remove an inactive workspace slot. The slot is removed only if it is still
    the registered instance for the canonical workspace identity. *)

val workspace_base_path : workspace -> string
