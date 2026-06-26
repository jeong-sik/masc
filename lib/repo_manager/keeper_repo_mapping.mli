open Repo_manager_types

val mappings_toml_basename : string
(** Basename of the keeper-repository mapping file.  Used as the policy
    source label in playground-repo responses so the JSON field stays in
    sync with the actual file name. *)

val mappings_toml_path : string -> string
(** [mappings_toml_path base_path] returns the absolute path to the
    keeper-repository mapping file for [base_path].  Exposed so tests and
    callers that need to write raw TOML use the same layout SSOT as the
    library. *)

val load_all : base_path:string -> (keeper_repo_mapping list, string) result
(** [load_all ~base_path] loads all keeper-repository mappings from
    [.masc/config/keeper_repo_mappings.toml]. *)

type mapping_lookup =
  | Mapping_found of keeper_repo_mapping
  | Mapping_missing of string
  | Mapping_load_error of string

val lookup_mapping : base_path:string -> keeper_id:string -> mapping_lookup
(** [lookup_mapping ~base_path ~keeper_id] loads the keeper mapping while
    preserving the missing/load-error distinction for fail-closed callers. *)

val mapping_allows_repository :
  keeper_repo_mapping -> repository_id:repository_id -> bool
(** [mapping_allows_repository mapping ~repository_id] applies the
    repository-id matching rules, including wildcard mappings. *)

type repository_scope =
  | All_repositories
  | Selected_repositories of repository_id list

val repository_scope_of_mapping : keeper_repo_mapping -> repository_scope
(** [repository_scope_of_mapping mapping] parses raw TOML repository IDs into
    the closed repository-scope representation used for policy decisions. *)

val find_mapping :
  base_path:string -> keeper_id:string -> (keeper_repo_mapping, string) result
(** [find_mapping ~base_path ~keeper_id] returns the mapping for [keeper_id]
    or an error if it is missing or the file cannot be loaded. *)

val allowed_repositories :
  keeper_id:string -> base_path:string -> (repository_id list, string) result
(** [allowed_repositories ~keeper_id ~base_path] returns the list of
    repository IDs that [keeper_id] is allowed to access. *)

val log_mapping_load_error_if_new : keeper_id:string -> string -> unit
(** Log a mapping load error once per keeper so operators notice file
    corruption/misconfiguration even on display-only paths that do not call
    {!is_allowed}. *)

val is_allowed :
  keeper_id:string -> repository_id:repository_id -> base_path:string -> bool
(** [is_allowed ~keeper_id ~repository_id ~base_path] returns [true] if
    [keeper_id] may access [repository_id]. *)

val validate_access :
  keeper_id:string -> repository_id:repository_id -> base_path:string -> (unit, string) result
(** [validate_access ~keeper_id ~repository_id ~base_path] returns [Ok ()] if
    access is permitted, or [Error msg] otherwise. *)

val save_mapping :
  base_path:string -> keeper_repo_mapping -> (unit, string) result
(** [save_mapping ~base_path mapping] saves or updates the mapping for the
    given keeper, overwriting any existing mapping for that keeper. *)

val apply_mapping :
  keeper_id:string -> base_path:string -> repositories:repository list -> repository list
(** [apply_mapping ~keeper_id ~base_path ~repositories] filters the given
    repository list to only those accessible by [keeper_id].
    When no mapping exists for the keeper, or mapping loading fails, no
    repositories are returned. *)

type repository_identity_mismatch

type repository_resolution =
  | No_repository
  | Repository of repository_id
  | Repository_identity_mismatch of repository_identity_mismatch
  | Repository_store_error of string

val repository_resolution_of_path :
  base_path:string -> path:string -> repository_resolution
(** [repository_resolution_of_path ~base_path ~path] returns the repository
    resolution for [path]. Use this for access decisions so identity mismatches
    and repository-store load failures stay explicit and fail closed. *)

val repository_id_of_path :
  base_path:string -> path:string -> repository_id option
(** [repository_id_of_path ~base_path ~path] returns the repository ID whose
    [local_path] contains [path], or [None] if the path is not under any
    registered repository or the registered repository has an identity
    mismatch. Compatibility wrapper only; do not use for access decisions
    because [None] collapses [No_repository], [Repository_identity_mismatch],
    and [Repository_store_error]. *)

val validate_path_access :
  keeper_id:string -> base_path:string -> path:string -> (unit, string) result
(** [validate_path_access ~keeper_id ~base_path ~path] returns [Ok ()] if
    [keeper_id] may access the repository containing [path], or if [path] is
    not under any registered repository. Returns [Error msg] for denied
    repositories, identity mismatches, and repository-store load failures. *)
