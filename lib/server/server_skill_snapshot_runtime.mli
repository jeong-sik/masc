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
