open Repo_manager_types

val clone : repository:repository -> (unit, string) result
(** [clone ~repository] clones [repository.url] into [repository.local_path]. *)

val run_git :
  cwd:string -> ?env:(string * string) list -> string list -> (string list, string) result
(** [run_git ~cwd args] runs [git -C cwd args] through the repo-manager Git
    execution wrapper and returns non-empty stdout lines. Callers must pass
    argv tokens, never shell text. *)

val fetch : repository:repository -> (string list, string) result
(** [fetch ~repository] fetches all remotes and returns the list of remote
    branch names. *)

val fast_forward :
  repository:repository -> target_ref:string -> (unit, string) result
(** [fast_forward ~repository ~target_ref] advances the current branch to
    [target_ref] with [git merge --ff-only]. Returns [Error] (without mutating
    history) when the move is not a pure fast-forward, so a divergent working
    tree is never overwritten. The target ref must already be fetched. *)

val get_branches :
  repository:repository -> (string list, string) result
(** [get_branches ~repository] returns all local and remote branch names. *)

val get_origin_url : local_path:string -> (string, string) result
(** [get_origin_url ~local_path] returns the configured [origin] remote URL
    for the repository at [local_path]. *)

val get_recent_commits :
  repository:repository -> branch:string -> limit:int -> (string list, string) result
(** [get_recent_commits ~repository ~branch ~limit] returns the most recent
    [limit] commits on [branch] as ["HASH subject"] lines. *)
