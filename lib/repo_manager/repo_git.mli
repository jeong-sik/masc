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
(** [clone ~repository] clones [repository.url] into [repository.local_path].
    Over HTTP(S), a transfer that moves less than a byte a second for a minute
    fails with git's own error. *)

val run_git :
  cwd:string ->
  ?env:(string * string) list ->
  ?timeout_sec:float ->
  string list ->
  (string list, string) result
(** [run_git ~cwd args] runs [git -C cwd args] through the repo-manager Git
    execution wrapper and returns non-empty stdout lines. Callers must pass
    argv tokens, never shell text. *)

val run_git_read_only_raw : cwd:string -> string list -> (string, string) result
(** [run_git] without splitting: the exact stdout bytes, read with
    [GIT_OPTIONAL_LOCKS=0] and no prompt, for a reader that must keep a
    commit's or a file's bytes as they are. No timeout. *)

val fetch : repository:repository -> (string list, string) result
(** [fetch ~repository] fetches all remotes and returns the list of remote
    branch names. Over HTTP(S), a transfer that moves less than a byte a
    second for a minute fails with git's own error, and the sync records that
    error. *)

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
  ?timeout_sec:float -> local_path:string -> unit -> (checkout_identity, string) result
(** [checkout_identity ~local_path] answers both questions in one
    read-only, bounded git invocation ([--path-format=absolute]).
    Errors mirror [worktree_root]: not a repository, timeout, or
    unexpected output shape. *)

val common_dir :
  ?timeout_sec:float -> local_path:string -> unit -> (string, string) result
(** Read the absolute Git common directory, including for a bare repository or
    an origin pointing at a Git directory. Read-only and bounded by the same
    inspection contract as {!checkout_identity}. *)

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

val status_files_at :
  ?timeout_sec:float -> local_path:string -> unit -> (status_file list, string) result
(** [status_files_at ~local_path] returns every staged, unstaged, untracked, or
    conflicted path of the checkout at [local_path]. It runs a read-only status
    command in porcelain-v1's NUL-delimited form, so spaces, newlines,
    non-ASCII bytes, and Git's display quoting never change a path's identity.
    Rename detection is disabled so every row has exactly one path. Workspace
    routes whose Git checkout is not registered in {!Repo_store} read through
    it. The caller remains responsible for proving that [local_path] is the
    requested scope's repository root. *)

(** How the checked-out branch relates to the branch it tracks. *)
type upstream_state =
  | No_upstream  (** The branch has no configured upstream. *)
  | Upstream_gone of string
      (** An upstream is configured but its ref no longer exists, so Git
          reports no ahead/behind counts. *)
  | Tracking of { upstream : string; ahead : int; behind : int }
      (** [ahead] local commits are not on [upstream]; [behind] upstream
          commits are not local. *)

type branch_status =
  | Detached
  | On_branch of { name : string; upstream : upstream_state }

val branch_status_of_porcelain_v2_z : string -> (branch_status, string) result
(** Pure reader for the header records of
    [git status --porcelain=v2 --branch -z]. A missing [branch.head] or a
    malformed [branch.ab] is an [Error _]; it never defaults to a branch. *)

val branch_status_at :
  ?timeout_sec:float -> local_path:string -> unit -> (branch_status, string) result
(** [branch_status_at ~local_path] reads the checked-out branch and its upstream
    counts from one read-only [git status --porcelain=v2 --branch] call. The
    caller remains responsible for proving that [local_path] is the requested
    scope's repository root. *)

val file_paths_at :
  ?timeout_sec:float -> local_path:string -> unit -> (string list, string) result
(** Enumerate tracked and nonignored untracked paths relative to the checkout
    root, without changing the index. NUL framing preserves exact path bytes;
    repeated index stages produce one path. Deleted tracked paths may still
    appear: the caller checks availability and its own file access policy.
    The caller must establish that [local_path] is its authorised Git root. *)

(** One local branch. *)
type branch_entry = {
  be_name : string;
  be_current : bool;  (** The checked-out branch. A detached HEAD marks none. *)
  be_upstream : upstream_state;
  be_commit_epoch : int;  (** Committer time of the branch tip, Unix seconds. *)
  be_subject : string;  (** First line of the tip commit message. *)
}

type branch_list = {
  bl_entries : branch_entry list;
      (** Newest tip first. A cut list keeps its first [max_entries] branches
          and then the checked-out branch when the cut dropped it. *)
  bl_truncated : bool;  (** More branches existed than [max_entries]. *)
}

val branch_list_of_for_each_ref :
  max_entries:int -> string -> (branch_list, string) result
(** Pure reader for the [for-each-ref] output of {!branches_at}: one line per
    branch, six NUL-separated fields. A malformed record, an unreadable
    ahead/behind field, or counts without an upstream is an [Error _]; none is
    skipped or read as "in step". *)

val branches_at :
  ?timeout_sec:float ->
  local_path:string ->
  max_entries:int ->
  unit ->
  (branch_list, string) result
(** Local branches of the checkout at [local_path], newest tip first, with each
    one's upstream relation. Read-only ([--no-optional-locks]) and bounded by
    [timeout_sec]. The caller proves that [local_path] is its authorised Git
    root. An empty repository is [Ok] with no entries. *)

(** What a worktree has checked out. *)
type worktree_state =
  | Worktree_branch of string  (** A local branch, without [refs/heads/]. *)
  | Worktree_detached
  | Worktree_bare

(** One linked or main worktree. The directory is reduced to its last path
    component: the list is meant for clients that must not learn the host's
    directory layout. *)
type worktree_entry = {
  wt_name : string;
  wt_main : bool;  (** The first record of git's list is the main worktree. *)
  wt_head : string option;  (** Full commit id. [None] only for a bare entry. *)
  wt_state : worktree_state;
  wt_locked : bool;  (** The lock reason is not kept. *)
  wt_prunable : bool;  (** Git reports the checkout directory as gone. *)
}

type worktree_list = {
  wl_entries : worktree_entry list;  (** In git's order, main worktree first. *)
  wl_truncated : bool;  (** More worktrees existed than [max_entries]. *)
}

val worktree_list_of_porcelain :
  max_entries:int -> string -> (worktree_list, string) result
(** Pure reader for [git worktree list --porcelain -z]: fields end at a NUL and
    records at an empty field. A record without a path, without a checkout
    state, with two states, with an unknown field, or cut short is an
    [Error _]; none is skipped. *)

val worktrees_at :
  ?timeout_sec:float ->
  local_path:string ->
  max_entries:int ->
  unit ->
  (worktree_list, string) result
(** Worktrees of the repository at [local_path], read-only and bounded by
    [timeout_sec]. [-z] needs git 2.36 or later; an older git fails with its own
    message, which is returned as [Error _]. The caller proves that
    [local_path] is its authorised Git root. *)

val status_snapshot_at :
  ?timeout_sec:float ->
  local_path:string ->
  unit ->
  (status_file list * branch_status, string) result
(** [status_snapshot_at ~local_path] is {!status_files_at} and
    {!branch_status_at} together. Two read-only Git calls, so a concurrent Git
    command can land between them; either failing is an [Error _]. Every route
    that answers a Git changes request reads through this, so none of them can
    answer without the branch. *)

type grep_match = {
  gm_path : string;  (** Relative to the repository root. *)
  gm_line : int;  (** 1-based. *)
  gm_text : string;  (** The matching source line, raw bytes. *)
}

type grep_result = {
  gr_matches : grep_match list;
  gr_truncated : bool;
      (** More matches may exist: rows passed [max_matches], or a file reached
          the per-file cap of 20 rows, where git stops reading it. *)
}

val grep_result_of_z_output :
  max_matches:int -> string -> (grep_result, string) result
(** Pure reader for [git grep -n -z] output ([path NUL line NUL text LF] per
    row; a path may contain a newline). Keeps the first [max_matches] rows. A malformed row, including the
    truncation marker the process capture inserts into oversized output, is an
    [Error _]; it is never skipped. *)

val grep_at :
  ?timeout_sec:float ->
  local_path:string ->
  pathspec:string ->
  pattern:string ->
  ignore_case:bool ->
  max_matches:int ->
  unit ->
  (grep_result, string) result
(** [grep_at ~local_path ~pathspec ~pattern ~ignore_case ~max_matches ()] is a
    read-only fixed-string search over tracked and non-ignored untracked text
    files under [pathspec] (a literal path relative to [local_path]; [""] is the
    whole repository). [pattern] is never a regular expression and never an
    option. No match is [Ok {gr_matches = []; _}]; Git failing or timing out is an
    [Error _]. At most 20 matches per file are read. Rows are in path, then
    line order. Tracked files are read whether or not an ignore rule matches
    them. The caller remains
    responsible for proving that [local_path] is the requested scope's
    repository root and for dropping paths the operator may not read. *)
