(** Server orchestration boundary for workspace Skill snapshot publication. *)

type error = Invalid_workspace of Config_dir_resolver.canonical_base_path_error

val refresh_from_config_text :
  base_path:string ->
  string ->
  (Skill_catalog_snapshot_service.publication, error) result

val refresh_from_runtime_file :
  base_path:string ->
  (Skill_catalog_snapshot_service.publication, error) result

val current :
  base_path:string -> (Skill_catalog_snapshot.t option, error) result

val snapshot_of_publication :
  Skill_catalog_snapshot_service.publication -> Skill_catalog_snapshot.t option

val error_to_string : error -> string
