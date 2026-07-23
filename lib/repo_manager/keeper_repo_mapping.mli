val mappings_toml_path : string -> string
(** Return the workspace-relative keeper repository preference file. *)

val load_all :
  base_path:string -> (Repo_manager_types.keeper_repo_mapping list, string) result
(** Load every keeper repository preference. Missing files produce an empty
    list; malformed or unreadable files produce an explicit error. *)

val save_mapping :
  base_path:string ->
  Repo_manager_types.keeper_repo_mapping ->
  (unit, string) result
(** Insert or replace one keeper's repository preference. These preferences
    drive product defaults only; they are not an authorization boundary. *)
