(** Server orchestration boundary for workspace Skill snapshot publication. *)

type error = Invalid_workspace of Config_dir_resolver.canonical_base_path_error

type lookup =
  | Not_registered
  | Uninitialized
  | Ready of Skill_catalog_snapshot.t

val refresh_from_runtime_file :
  base_path:string ->
  (Skill_catalog_snapshot_service.publication, error) result

val lookup : base_path:string -> (lookup, error) result

val error_to_string : error -> string
