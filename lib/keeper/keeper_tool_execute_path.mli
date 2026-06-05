(** {1 Path resolution} *)

val resolve_tool_read_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_tool_write_cwd :
  allow_side_effects:bool ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve an Execute cwd inside the keeper write boundary. When
    [allow_side_effects] is [false], resolution performs no mkdir, repo
    fast-forward, reclone, or worktree repair. *)

val validate_repo_path_args_ready :
  ?allow_repair:bool ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Reject typed Execute path arguments that point into a sandbox [repos/<repo>]
    directory unless that repo is an independent git checkout. This catches
    commands run from the playground root with arguments like
    [./repos/masc/lib/foo.ml]. *)

val validate_repo_cwd_currency_ready :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  allow_stale_preserved_repo_context:bool ->
  (unit, string) result
(** Reject typed Execute commands from a preserved sandbox [repos/<repo>] root
    or subpath when the repo could not be advanced to [origin/main]. Dirty,
    detached, task-branch, diverged, or unregistered roots are preserved by the
    repo currency layer; this guard prevents normal work from continuing against
    that stale root. Repo worktree cwd values are not gated here. Command-shape
    policy is decided by the caller through [allow_stale_preserved_repo_context]. *)

type repo_cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }
(** Path-only facts for a cwd inside a keeper sandbox repo. [path_root] is the
    selected git toplevel expected for the cwd: either [repo_root] or a worktree
    root. *)

val repo_cwd_context :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  repo_cwd_context option
(** Classify [cwd] as a keeper sandbox repo cwd. This reports path facts only;
    callers own command-shape and write-gate policy. *)

val invalidate_repo_currency_cache :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  unit
(** Clear the cached currency probe for [repo_name]. Callers decide when a
    command is allowed to mutate repo currency. *)

val execution_location_json :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  cwd:string ->
  Yojson.Safe.t
(** Structured cwd contract for Execute responses.  The JSON tells the agent
    whether the effective cwd is inside the keeper playground
    ([playground_root], [playground_subpath], [repo_root], [repo_subpath],
    [repo_worktree_root], [repo_worktree_subpath]) or outside it
    ([outside_playground]).  [relative_cwd] is relative to [playground_root]
    for playground scopes and [null] when the cwd is outside the playground.
    Relative argv paths resolve against the effective cwd.  Worktree scopes also
    carry [worktree_selected] and [selected_worktree] so the keeper can observe
    the selected repo/worktree assignment without reparsing [cwd]. *)

val auto_correct_path :
  meta:Keeper_meta_contract.keeper_meta -> string -> string option
(** Auto-correct common LLM-hallucinated path prefixes
    ([/repos/…], [repos/…], [playground/…]) into the keeper's
    real playground bundle path.  Sanitization of [meta.name]
    happens through {!Playground_paths}. *)

val resolve_tool_read_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve the [path] arg against the keeper's read root, with
    {!auto_correct_path} as a fallback when the initial resolution
    fails.  Guards against playground-prefix doubling when both
    [cwd] and [path] independently include the playground prefix. *)

val shell_command_available : string -> bool
(** PATH executable probe for workspace read fallback selection.
    This intentionally avoids [/bin/sh -c] and does not treat empty
    PATH entries as the current directory. *)

val in_playground :
  root:string -> cwd:string -> meta:Keeper_meta_contract.keeper_meta -> bool
(** [true] when [cwd] is inside the keeper's sandbox playground,
    or equal to it.  Normalises both paths before comparison so that
    trailing slashes do not affect the result. *)
