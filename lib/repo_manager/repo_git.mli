open Repo_manager_types

type status_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
}
(** Summary parsed from Git's porcelain-v1 status contract. *)

val clone : repository:repository -> (unit, string) result
(** [clone ~repository] clones [repository.url] into [repository.local_path]. *)

val run_git :
  cwd:string ->
  ?env:(string * string) list ->
  ?timeout_sec:float ->
  string list ->
  (string list, string) result
(** [run_git ~cwd args] runs [git -C cwd args] through the repo-manager Git
    execution wrapper and returns non-empty stdout lines. Callers must pass
    argv tokens, never shell text. *)

val fetch : repository:repository -> (string list, string) result
(** [fetch ~repository] fetches all remotes and returns the list of remote
    branch names. *)

val fast_forward :
  repository:repository -> target_ref:string -> (unit, string) result
(** [fast_forward ~repository ~target_ref] advances the current branch to
    [target_ref] with a hook-suppressed [git merge --ff-only]. Returns [Error]
    (without mutating history) when the move is not a pure fast-forward, so a
    divergent working tree is never overwritten. The target ref must already be
    fetched. *)

val get_branches :
  repository:repository -> (string list, string) result
(** [get_branches ~repository] returns all local and remote branch names. *)

val get_origin_url : local_path:string -> (string, string) result
(** [get_origin_url ~local_path] returns the configured [origin] remote URL
    for the repository at [local_path]. *)

val worktree_root : local_path:string -> (string, string) result
(** [worktree_root ~local_path] returns Git's [--show-toplevel] path for
    [local_path]. It is read-only and bounded; callers use it to avoid treating
    an arbitrary file's dirname as a repository root. *)

val origin_head_branch : local_path:string -> (string, string) result
(** [origin_head_branch ~local_path] returns the branch named by
    [refs/remotes/origin/HEAD]. It does not fall back to guessed branch names;
    callers that need an auditable repository-registration candidate should
    surface [Error _] to the operator instead of inventing a default branch. *)

val current_branch : repository:repository -> (string, string) result
(** [current_branch ~repository] returns the short name of the checked-out
    branch via [git rev-parse --abbrev-ref HEAD]. A detached HEAD returns
    ["HEAD"]. Read-only ([GIT_OPTIONAL_LOCKS=0]) with a bounded timeout. *)

val ahead_behind :
  repository:repository -> target_ref:string -> (int * int, string) result
(** [ahead_behind ~repository ~target_ref] returns [(behind, ahead)]:
    [behind] counts commits reachable from [target_ref] but not from HEAD,
    [ahead] the reverse, via
    [git rev-list --left-right --count <target_ref>...HEAD]. The target ref
    must already be fetched. Read-only with a bounded timeout. *)

val get_recent_commits :
  repository:repository -> branch:string -> limit:int -> (string list, string) result
(** [get_recent_commits ~repository ~branch ~limit] returns the most recent
    [limit] commits on [branch] as ["HASH subject"] lines. *)

val status_summary : repository:repository -> (status_summary, string) result
(** [status_summary ~repository] returns a read-only dirty-tree summary using
    [git --no-optional-locks status --porcelain=v1] with
    [GIT_OPTIONAL_LOCKS=0]. It returns [Error _] instead of inventing a clean
    result when Git cannot inspect the repository. *)
