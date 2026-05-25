(** GitHub repository slug and origin discovery for keeper GH tools.

    GH command parsing lives in {!Keeper_gh_shared}; this module owns the
    repository slug helpers and the host-side [git remote get-url] fallback. *)

val has_repo_flag : string -> bool

val is_valid_repo_segment : string -> bool

val validate_repo_slug : string -> (string, string) result

val strip_repo_flags_from_args : string list -> string list

val args_have_repo_flag : string list -> bool

val inject_repo_flag_args : repo_slug:string -> string list -> string list

val repo_slug_of_remote_url : string -> string option

val repo_slug_of_git_config : git_root:string -> string option

val repo_slug_of_task_worktree :
  git_root:string -> worktree_cwd:string -> string option

val repo_slug_of_git_root : git_root:string -> string option
