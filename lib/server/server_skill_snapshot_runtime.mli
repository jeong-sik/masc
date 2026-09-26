(** Server orchestration boundary for workspace Skill snapshot publication. *)

type error = Invalid_workspace of Config_dir_resolver.canonical_base_path_error

type lookup =
  | Not_registered
  | Uninitialized
  | Ready of Skill_catalog_snapshot.t

type commit_application =
  | Applied of
      { input_source_revision : Runtime.config_source_revision
      ; publication : Skill_catalog_snapshot_service.publication
      }
  | Superseded of
      { commit_order : Runtime.config_commit_order
      ; applied_order : Runtime.config_commit_order
      }

val refresh_from_observation :
  base_path:string ->
  Runtime.config_observation ->
  (Skill_catalog_snapshot_service.publication, error) result
(** Publish the Skill snapshot for runtime.toml as [observation] read it. When
    this replaces an earlier snapshot and the config state changes (configured,
    rejected, unreadable), the change is logged once with the reason and the
    file. The first publication logs nothing here: that one is boot's, and
    [boot_report] names it. *)

val apply_commit :
  base_path:string ->
  Runtime.config_commit_receipt ->
  (commit_application, error) result

val lookup : base_path:string -> (lookup, error) result
val publish_lane_skills :
  config:Workspace.config -> Lane_addon_runtime.skill_export list -> (unit, string) result
(** Compose explicit package Skill sources with the normal workspace source
    catalog. Missing package sources and absent read policy are local export
    diagnostics; runtime.toml and Keeper prompts are not modified. *)

val error_to_string : error -> string

type boot_level =
  | Boot_info
  | Boot_warn
  | Boot_error

val boot_report :
  runtime_config_path:string -> Skill_catalog_snapshot.t -> boot_level * string
(** The boot log line for a published Skill snapshot. Pure so the line is
    tested; the bootstrap only chooses the logger for the level. A rejected
    [skills] table is a WARN carrying every diagnostic and the file path. *)
