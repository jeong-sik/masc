(** Worktree_live_context — Capture per-keeper "has the working tree
    changed since last turn?" signal for world-observation blocks.

    On each call, runs [git status --porcelain] against the base_path
    repo, compares a stable hash against the previous turn's hash for
    the given [actor_key], and emits a formatted
    [<git_status_change>] block only when the hash differs.

    Cache state persists under
    [<repo_root>/.masc/worktree-live-context/<actor_key>.hash].
    Test hooks for injecting a deterministic git capture are kept
    internal and not part of the public interface. *)

(** [capture_change_block ~base_path ~actor_key] returns
    - [Some block] — a [<git_status_change>] XML block with up to 20
      visible lines, when the working tree has changed since the last
      call for [actor_key].
    - [None] — when the repo cannot be located, when no changes are
      present, or when the hash matches the previous call. *)
val capture_change_block :
  base_path:string -> actor_key:string -> string option

(** {1 Test hooks}

    Production code should not call these. *)

(** Capture hook signature: [~workdir args] → optional stdout lines
    from the stubbed [git] invocation. *)
type git_capture_hook =
  workdir:string -> string list -> string list option

(** Install a deterministic git capture used instead of spawning
    [git] via {!Masc_exec.Exec_gate}. *)
val set_git_capture_hook_for_tests : git_capture_hook -> unit

(** Remove any previously installed {!set_git_capture_hook_for_tests}
    hook. *)
val clear_git_capture_hook_for_tests : unit -> unit

(** Reset the in-memory per-repo status cache so tests observe a
    deterministic "no previous hash" state. *)
val clear_status_cache_for_tests : unit -> unit

(** [current_status_lines ~repo_root] returns the cached
    [git status --porcelain] lines for [repo_root], refreshing from
    disk on cache miss. *)
val current_status_lines : repo_root:string -> string list
