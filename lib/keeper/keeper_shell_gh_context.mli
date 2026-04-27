(** GH repo context resolution for keeper shell commands.

    Extracted from keeper_exec_shell.ml — types and resolution logic
    for binding a keeper's active task to a git repository context,
    including worktree path validation and origin slug detection. *)

(** Successfully resolved GitHub repo context for a keeper's active task. *)
type gh_repo_context =
  { task_id : string
  ; git_root : string
  ; worktree_cwd : string
  ; repo_slug : string option
  }

(** Failure to resolve a [gh_repo_context], with structured fields for
    JSON serialization. *)
type gh_repo_context_error =
  { code : string
  ; detail : string
  ; hint : string
  ; task_id : string option
  ; git_root : string option
  ; worktree_path : string option
  }

(** Smart-constructor for [gh_repo_context_error] that takes optional
    location fields. *)
val gh_repo_context_error :
  ?task_id:string ->
  ?git_root:string ->
  ?worktree_path:string ->
  code:string ->
  detail:string ->
  hint:string ->
  unit ->
  gh_repo_context_error

(** Common hint instructing the keeper to call [keeper_task_claim] before
    using [keeper_shell op=gh]. *)
val gh_claim_first_hint : string

(** Render a [gh_repo_context_error] as the canonical
    [{ ok=false; op; command; error; error_category; ... }] JSON envelope. *)
val gh_repo_context_error_json :
  op:string -> cmd_display:string -> gh_repo_context_error -> string

(** Resolve the active task's repo context for [keeper_shell op=gh].
    Falls back to a sandbox context when [meta.current_task_id] is
    [None]; otherwise validates the task's worktree and origin slug. *)
val resolve_gh_repo_context :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  (gh_repo_context, gh_repo_context_error) result
