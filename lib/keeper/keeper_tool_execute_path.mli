(** {1 Path resolution} *)

val resolve_tool_read_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_tool_write_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val validate_repo_path_args_ready :
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
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Reject non-diagnostic typed Execute commands from a direct sandbox
    [repos/<repo>] cwd when the repo could not be advanced to
    [origin/main]. Dirty, detached, task-branch, diverged, or unregistered
    direct roots are preserved by the repo currency layer; this guard prevents
    normal work from continuing against that stale root while still allowing
    focused git diagnostics. Repo worktree cwd values are not gated here. *)

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
