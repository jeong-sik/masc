open Repo_manager_types

val clone :
  repository:repository -> credential:credential -> (unit, string) result
(** [clone ~repository ~credential] clones [repository.url] into
    [repository.local_path] using the given credential. *)

val fetch :
  repository:repository -> credential:credential -> (string list, string) result
(** [fetch ~repository ~credential] fetches all remotes and returns the list of
    remote branch names. *)

val checkout_worktree :
  repository:repository -> branch:string -> (string, string) result
(** [checkout_worktree ~repository ~branch] creates or checks out a git
    worktree for [branch] under the repository. Returns the worktree path. *)

val get_branches :
  repository:repository -> (string list, string) result
(** [get_branches ~repository] returns all local and remote branch names. *)

val get_recent_commits :
  repository:repository -> branch:string -> limit:int -> (string list, string) result
(** [get_recent_commits ~repository ~branch ~limit] returns the most recent
    [limit] commits on [branch] as ["HASH subject"] lines. *)
