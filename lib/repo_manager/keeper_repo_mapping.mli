open Repo_manager_types

val load_all : base_path:string -> (keeper_repo_mapping list, string) result
(** [load_all ~base_path] loads all keeper-repository mappings from
    [.masc/config/keeper_repo_mappings.toml]. *)

val allowed_repositories :
  keeper_id:string -> base_path:string -> (repository_id list, string) result
(** [allowed_repositories ~keeper_id ~base_path] returns the list of
    repository IDs that [keeper_id] is allowed to access. *)

val credentials_for_keeper :
  base_path:string -> keeper_id:string -> (credential list, string) result
(** [credentials_for_keeper ~base_path ~keeper_id] resolves the
    credential currently mapped to [keeper_id].  A direct
    [credential_id] on the keeper mapping wins; otherwise this resolves
    the unique credentials by walking every repository the keeper is
    allowed to access and looking up each repository's [credential_id] in
    the credential store.

    Returns [Ok []] when the keeper has no mapping (backward-compatibility
    signal consumed by the RFC-0019 PR-A credential provider bridge).
    Returns [Error _] only on infrastructure failure (mapping store
    unreadable, referenced credential missing). *)

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
    When no mapping exists for the keeper, all repositories are returned
    (backward compatibility). *)

val repository_id_of_path :
  base_path:string -> path:string -> repository_id option
(** [repository_id_of_path ~base_path ~path] returns the repository ID whose
    [local_path] contains [path], or [None] if the path is not under any
    registered repository. *)

val validate_path_access :
  keeper_id:string -> base_path:string -> path:string -> (unit, string) result
(** [validate_path_access ~keeper_id ~base_path ~path] returns [Ok ()] if
    [keeper_id] may access the repository containing [path], or if [path] is
    not under any registered repository. Returns [Error msg] otherwise. *)
