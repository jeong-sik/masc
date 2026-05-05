open Repo_manager_types

val load_all : base_path:string -> (repository list, string) result
(** [load_all ~base_path] reads [.masc/config/repositories.toml] and returns
    all registered repositories. Returns [Ok []] if the file does not exist. *)

val save_all : base_path:string -> repository list -> (unit, string) result
(** [save_all ~base_path repos] writes [repos] to
    [.masc/config/repositories.toml], replacing any previous content. *)

val find : base_path:string -> repository_id -> (repository, string) result
(** [find ~base_path id] returns the repository with the given [id]. *)

val add : base_path:string -> repository -> (repository, string) result
(** [add ~base_path repo] adds [repo] to the store. If a repository with the
    same [id] already exists, returns an error. *)

val remove : base_path:string -> repository_id -> (unit, string) result
(** [remove ~base_path id] removes the repository with the given [id]. *)

val update_status :
  base_path:string -> repository_id -> repository_status -> (unit, string) result
(** [update_status ~base_path id status] updates the status of the repository
    with the given [id]. *)

val update :
  base_path:string -> repository_id -> repository -> (repository, string) result
(** [update ~base_path id repo] replaces the repository with the given [id]
    with [repo], applying the same field normalization as {!add} (default
    [local_path] and [credential_id] when blank) and forcing [repo.id = id].
    Preserves the original [created_at] and stamps a fresh [updated_at].
    Returns the persisted repository record. *)

val list_branches :
  base_path:string -> repository_id -> (string list, string) result
(** [list_branches ~base_path id] lists branch names for the repository.
    This delegates to the git layer and will be wired once {!Repo_git} is
    available. *)

val local_path : base_path:string -> repository -> string
(** [local_path ~base_path repo] returns the absolute path to the repository's
    local checkout. If [repo.local_path] is already absolute, it is returned
    as-is; otherwise it is resolved relative to [base_path]. *)

val discover_repositories : base_path:string -> (repository list, string) result
(** [discover_repositories ~base_path] scans [base_path] for git repositories
    (directories containing [.git] up to depth 4) and returns a list of
    candidate {!repository} records inferred from their [origin] remote URL.

    Directories under [.masc/] and repositories already registered in
    [repositories.toml] are excluded. This function is read-only and is
    intended for Phase 1 onboarding where the operator confirms discovered
    repositories before adding them to the store. *)

val register_discovered : base_path:string -> (repository list, string) result
(** [register_discovered ~base_path] scans [base_path] for git repositories
    using {!discover_repositories} and automatically persists each candidate.
    Repositories that already exist (same [id]) may be skipped; store failures
    are returned to the caller as [Error _]. On success, returns the list of
    newly registered repositories.

    This is the Week 8 migration helper: existing users with git
    repositories under their base path can call this once to populate
    [repositories.toml] without manual registration. *)
