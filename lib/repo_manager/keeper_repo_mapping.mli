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
(** [load_all ~base_path] loads all keeper-repository mappings from the path
    returned by {!mappings_toml_path}. A malformed top-level [[mapping]]
    section returns an [Error]. *)

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

type repository_scope = Repo_manager_types.repository_scope =
  | All_repositories
  | Selected_repositories of repository_id list

val repository_scope_of_mapping : keeper_repo_mapping -> repository_scope
(** [repository_scope_of_mapping mapping] returns the parsed repository scope
    produced at the TOML/JSON boundary. *)

val find_mapping :
  base_path:string -> keeper_id:string -> (keeper_repo_mapping, string) result
(** [find_mapping ~base_path ~keeper_id] returns the mapping for [keeper_id]
    or an error if it is missing or the file cannot be loaded. *)

val allowed_repositories :
  keeper_id:string -> base_path:string -> (repository_id list, string) result
(** [allowed_repositories ~keeper_id ~base_path] returns the list of
    repository IDs that [keeper_id] is allowed to access. A keeper without an
    explicit mapping inherits the default wildcard scope [["*"]]; malformed
    mapping files still fail closed. *)

val log_mapping_load_error_if_new : keeper_id:string -> string -> unit
(** Log a mapping load error once per keeper so operators notice file
    corruption/misconfiguration even on display-only paths that do not call
    {!is_allowed}. *)

type access_denial =
  | Access_denied_unregistered_repository of repository_id
  | Access_denied_not_in_mapping of
      { keeper_id : string
      ; repository_id : repository_id
      }
  | Access_denied_load_error of string
  | Access_denied_repository_store_error of
      { repository_id : repository_id
      ; detail : string
      }

type access_decision =
  | Access_allowed
  | Access_denied of access_denial

val access_denial_to_string : access_denial -> string

val access_decision :
  keeper_id:string ->
  repository_id:repository_id ->
  base_path:string ->
  access_decision
(** [access_decision ~keeper_id ~repository_id ~base_path] is the typed
    repository access gate. Use it when a caller needs to distinguish a
    claimable selected-scope miss from hard fail-closed cases. *)

type policy_decision =
  | Policy_decision_default_scope_allowed
  | Policy_decision_unregistered_repository
  | Policy_decision_not_in_mapping
  | Policy_decision_load_error
  | Policy_decision_repository_identity_mismatch
  | Policy_decision_repository_store_error

val record_policy_decision :
  keeper_id:string -> ?repository_id:string -> policy_decision -> unit
(** Record a keeper-repository mapping policy decision in the operator
    metrics. Callers should increment once per decision so implicit
    default-scope access, unregistered repository denials,
    denied-not-in-mapping, load-error, repository identity mismatch, and
    repository store load-error paths are observable. *)

val is_allowed :
  keeper_id:string -> repository_id:repository_id -> base_path:string -> bool
(** [is_allowed ~keeper_id ~repository_id ~base_path] returns [true] if
    [keeper_id] may access [repository_id]. Missing mappings use the
    registered-repository default wildcard scope so keeper-local clones are
    usable without a per-keeper mapping entry; malformed mappings and
    unregistered repository IDs remain deny-by-error. *)

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
    When no mapping exists for the keeper, all repositories are returned.
    Mapping load failures still return no repositories. *)

type repository_identity_mismatch
type repository_origin_read_error

val repository_origin_read_error_message :
  repository_origin_read_error -> string
(** Render the operator-facing fail-closed explanation for a playground
    repository whose git origin could not be read. *)

val repository_identity_mismatch_message : repository_identity_mismatch -> string

type repository_resolution =
  | No_repository
  | Repository of repository_id
  | Repository_identity_mismatch of repository_identity_mismatch
  | Repository_origin_read_error of repository_origin_read_error
  | Repository_store_error of string

val repository_resolution_of_path :
  base_path:string -> path:string -> repository_resolution
(** [repository_resolution_of_path ~base_path ~path] returns the repository
    resolution for [path]. Use this for access decisions so identity mismatches
    repository-origin read failures, and repository-store load failures stay
    explicit and fail closed. *)

val repository_resolution_of_path_from_catalog :
  base_path:string -> path:string -> repository list -> repository_resolution
(** [repository_resolution_of_path_from_catalog ~base_path ~path repos] is the
    same resolver using a caller-supplied repository catalog. Use this for
    display paths that resolve many sibling repositories in one request so they
    do not reload [repositories.toml] once per row. *)

val repository_id_of_path :
  base_path:string -> path:string -> repository_id option
(** [repository_id_of_path ~base_path ~path] returns the repository ID whose
    [local_path] contains [path], or [None] if the path is not under any
    registered repository or the registered repository has an identity
    mismatch. Compatibility wrapper only; do not use for access decisions
    because [None] collapses [No_repository], [Repository_identity_mismatch],
    [Repository_origin_read_error], and [Repository_store_error]. *)

val validate_path_access :
  keeper_id:string -> base_path:string -> path:string -> (unit, string) result
(** [validate_path_access ~keeper_id ~base_path ~path] returns [Ok ()] if
    [keeper_id] may access the repository containing [path], or if [path] is
    not under any registered repository. Returns [Error msg] for denied
    repositories, identity mismatches, and repository-store load failures. *)
