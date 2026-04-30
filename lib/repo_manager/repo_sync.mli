open Repo_manager_types

val sync_repository :
  base_path:string -> repository -> credential -> (unit, string) result
(** [sync_repository ~base_path repo credential] fetches the repository and
    updates its status to [Active] on success or [Error msg] on failure. *)

val should_sync : repository -> now:int64 -> bool
(** [should_sync repo ~now] returns [true] if [repo.auto_sync] is enabled and
    [now - repo.updated_at] exceeds [repo.sync_interval] seconds. *)

val sync_all :
  base_path:string -> now:int64 -> (repository list, string) result
(** [sync_all ~base_path ~now] loads all repositories, filters those that
    should_sync, fetches each one using its credential, and returns the list
    of successfully synced repositories. *)
