open Repo_manager_types

val inspection_timeout_sec : float
(** Total default budget for one request's repository Git inspection. *)

type origin_lookup_error =
  | Origin_missing
  | Origin_lookup_timed_out of string
  | Origin_lookup_failed of string

val origin_lookup_error_to_string : origin_lookup_error -> string

module Inspection_budget : sig
  type t

  val create : ?timeout_sec:float -> unit -> t
  (** Start one monotonic request budget. *)

  val remaining_timeout : t -> (float, string) result
  (** Return the positive timeout still available to the next Git subprocess,
      capped by {!inspection_timeout_sec}. *)

  val is_exhausted : t -> bool
end

type status_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
}
(** Summary parsed from Git's porcelain-v1 status contract. *)

type status_file = {
  path : string;
  staged : bool;
  unstaged : bool;
  untracked : bool;
  conflicted : bool;
}
(** One changed path from Git's NUL-delimited porcelain-v1 contract. *)

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

val get_origin_url :
  ?timeout_sec:float -> local_path:string -> unit -> (string, origin_lookup_error) result
(** [get_origin_url ~local_path] returns the configured [origin] remote URL
    for the repository at [local_path]. Missing configuration, a bounded
    timeout, and other Git failures remain distinct typed outcomes. *)

val worktree_root : local_path:string -> (string, string) result
(** [worktree_root ~local_path] returns Git's [--show-toplevel] path for
    [local_path]. It is read-only and bounded; callers use it to avoid treating
    an arbitrary file's dirname as a repository root. *)

type checkout_identity = {
  toplevel : string;
      (** Git's [--show-toplevel] for the queried path: the root of the
          checkout (main tree or linked worktree) that holds it. *)
  git_common_dir : string;
      (** Git's [--git-common-dir]: the shared [.git] directory of the
          repository the checkout belongs to. For a linked worktree
          this is the {e main} checkout's [.git]; for a nested foreign
          clone it is that clone's own [.git]. The pair lets a caller
          decide "worktree of THIS repo" without any path convention
          or remote-URL parsing. *)
}

val checkout_identity :
  local_path:string -> (checkout_identity, string) result
(** [checkout_identity ~local_path] answers both questions in one
    read-only, bounded git invocation ([--path-format=absolute]).
    Errors mirror {!worktree_root}: not a repository, timeout, or
    unexpected output shape. *)

val origin_head_branch : local_path:string -> (string, string) result
(** [origin_head_branch ~local_path] returns the branch named by
    [refs/remotes/origin/HEAD]. It does not fall back to guessed branch names;
    callers that need an auditable repository-registration candidate should
    surface [Error _] to the operator instead of inventing a default branch. *)

val current_branch :
  ?timeout_sec:float -> repository:repository -> unit -> (string, string) result
(** [current_branch ~repository] returns the short name of the checked-out
    branch via [git rev-parse --abbrev-ref HEAD]. A detached HEAD returns
    ["HEAD"]. Read-only ([GIT_OPTIONAL_LOCKS=0]) with a bounded timeout. *)

val ahead_behind :
  ?timeout_sec:float ->
  repository:repository ->
  target_ref:string ->
  unit ->
  (int * int, string) result
(** [ahead_behind ~repository ~target_ref] returns [(behind, ahead)]:
    [behind] counts commits reachable from [target_ref] but not from HEAD,
    [ahead] the reverse, via
    [git rev-list --left-right --count <target_ref>...HEAD]. The target ref
    must already be fetched. Read-only with a bounded timeout. *)

val get_recent_commits :
  repository:repository -> branch:string -> limit:int -> (string list, string) result
(** [get_recent_commits ~repository ~branch ~limit] returns the most recent
    [limit] commits on [branch] as ["HASH subject"] lines. *)

val status_summary :
  ?timeout_sec:float -> repository:repository -> unit -> (status_summary, string) result
(** [status_summary ~repository] returns a read-only dirty-tree summary using
    [git --no-optional-locks status --porcelain=v1] with
    [GIT_OPTIONAL_LOCKS=0]. It returns [Error _] instead of inventing a clean
    result when Git cannot inspect the repository. *)

val status_files :
  ?timeout_sec:float -> repository:repository -> unit -> (status_file list, string) result
(** [status_files ~repository] returns every staged, unstaged, untracked, or
    conflicted path. It uses porcelain-v1's NUL-delimited form, so spaces,
    newlines, non-ASCII bytes, and Git's display quoting never change a path's
    identity. Rename detection is disabled so every row has exactly one path. *)

val status_files_at :
  ?timeout_sec:float -> local_path:string -> unit -> (status_file list, string) result
(** [status_files_at ~local_path] is the path-based form used by workspace
    routes whose Git checkout is not registered in {!Repo_store}. It runs the
    same read-only, NUL-delimited status command as {!status_files}. The caller
    remains responsible for proving that [local_path] is the requested scope's
    repository root. *)
